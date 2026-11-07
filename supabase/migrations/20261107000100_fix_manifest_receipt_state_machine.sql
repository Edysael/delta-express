-- Delta-Express: preserve the shipment state machine during manifest reconciliation.
-- This migration is staged on the remediation branch; it is not applied to production.

CREATE OR REPLACE FUNCTION public.receive_manifest_reconciliation(
  p_manifest_id uuid,
  p_branch_id uuid,
  p_items jsonb,
  p_notes text DEFAULT NULL::text
)
RETURNS uuid
LANGUAGE plpgsql
SET search_path TO ''
AS $function$
DECLARE
  v_manifest public.manifests%ROWTYPE;
  v_receipt_id uuid;
  v_expected integer;
  v_submitted integer;
  v_result text;
  v_shipment_id uuid;
  v_notes text;
  v_current_status text;
  v_has_diff boolean := false;
  v_user uuid := auth.uid();
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'Debe iniciar sesión'; END IF;
  IF jsonb_typeof(p_items) IS DISTINCT FROM 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Debe registrar la conciliación de la carga';
  END IF;

  SELECT * INTO v_manifest
  FROM public.manifests
  WHERE id = p_manifest_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'Manifiesto no encontrado'; END IF;
  IF v_manifest.status NOT IN ('dispatched','received') THEN
    RAISE EXCEPTION 'El manifiesto no está en tránsito o ya fue recibido';
  END IF;
  IF v_manifest.destination_branch_id IS DISTINCT FROM p_branch_id THEN
    RAISE EXCEPTION 'La sucursal receptora no coincide con el destino del manifiesto';
  END IF;
  IF NOT private.can_access_branch(v_manifest.company_id, p_branch_id) THEN
    RAISE EXCEPTION 'No tiene acceso a la sucursal receptora';
  END IF;
  IF EXISTS (SELECT 1 FROM public.manifest_receipts r WHERE r.manifest_id=p_manifest_id) THEN
    RAISE EXCEPTION 'Este manifiesto ya tiene una recepción registrada';
  END IF;

  SELECT count(*) INTO v_expected
  FROM public.manifest_shipments ms
  WHERE ms.manifest_id=p_manifest_id AND ms.company_id=v_manifest.company_id;

  SELECT count(*) INTO v_submitted FROM jsonb_array_elements(p_items);
  IF v_expected <> v_submitted THEN
    RAISE EXCEPTION 'Debe conciliar todas las encomiendas del manifiesto. Esperadas: %, recibidas: %',v_expected,v_submitted;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_items) j
    LEFT JOIN public.manifest_shipments ms
      ON ms.manifest_id=p_manifest_id
     AND ms.company_id=v_manifest.company_id
     AND ms.shipment_id=(j->>'shipment_id')::uuid
    WHERE ms.shipment_id IS NULL
  ) THEN RAISE EXCEPTION 'La lista contiene encomiendas que no pertenecen al manifiesto'; END IF;

  IF (SELECT count(DISTINCT (j->>'shipment_id')::uuid) FROM jsonb_array_elements(p_items) j) <> v_submitted THEN
    RAISE EXCEPTION 'La conciliación contiene encomiendas duplicadas';
  END IF;

  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_items) j
    WHERE coalesce(j->>'result','') NOT IN ('recibido_conforme','recibido_danado','faltante')
       OR (j->>'result') <> 'recibido_conforme' AND length(trim(coalesce(j->>'notes',''))) < 5
  ) THEN RAISE EXCEPTION 'Las diferencias requieren observaciones de al menos cinco caracteres'; END IF;

  v_has_diff := EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_items) j
    WHERE j->>'result' <> 'recibido_conforme'
  );

  INSERT INTO public.manifest_receipts(company_id,manifest_id,branch_id,received_by,notes,reconciliation_status)
  VALUES(v_manifest.company_id,p_manifest_id,p_branch_id,v_user,nullif(trim(p_notes),''),CASE WHEN v_has_diff THEN 'con_diferencias' ELSE 'conforme' END)
  RETURNING id INTO v_receipt_id;

  FOR v_shipment_id,v_result,v_notes IN
    SELECT (j->>'shipment_id')::uuid,j->>'result',nullif(trim(j->>'notes'),'')
    FROM jsonb_array_elements(p_items) j
  LOOP
    SELECT s.status INTO v_current_status
    FROM public.shipments s
    WHERE s.id=v_shipment_id AND s.company_id=v_manifest.company_id
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Encomienda % no encontrada en la empresa', v_shipment_id;
    END IF;

    -- The state machine does not allow dispatched -> at_destination_branch/incident.
    -- Move dispatched shipments to in_transit first, within this same transaction.
    IF v_current_status='dispatched' THEN
      UPDATE public.shipments
      SET status='in_transit', updated_at=now()
      WHERE id=v_shipment_id AND company_id=v_manifest.company_id;
      v_current_status := 'in_transit';
    END IF;

    IF v_current_status NOT IN ('in_transit','at_destination_branch','incident') THEN
      RAISE EXCEPTION 'Estado de encomienda no conciliable: % (%)', v_shipment_id, v_current_status;
    END IF;

    INSERT INTO public.manifest_receipt_items(company_id,receipt_id,shipment_id,result,notes)
    VALUES(v_manifest.company_id,v_receipt_id,v_shipment_id,v_result,v_notes);

    IF v_result='recibido_conforme' AND v_current_status='in_transit' THEN
      UPDATE public.shipments SET status='at_destination_branch', updated_at=now()
      WHERE id=v_shipment_id AND company_id=v_manifest.company_id;
    ELSIF v_result='recibido_danado' AND v_current_status='in_transit' THEN
      UPDATE public.shipments SET status='incident', updated_at=now()
      WHERE id=v_shipment_id AND company_id=v_manifest.company_id;
    END IF;
    -- A faltante remains in transit; it is not falsely marked as received.
  END LOOP;

  UPDATE public.manifests
  SET status='received', received_at=now()
  WHERE id=p_manifest_id AND company_id=v_manifest.company_id;

  RETURN v_receipt_id;
END;
$function$;

-- Prevent direct API updates from marking a manifest received without a
-- completed reconciliation record. The RPC above inserts the receipt first.
CREATE OR REPLACE FUNCTION private.require_manifest_receipt_before_received()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO ''
AS $function$
BEGIN
  IF NEW.status='received'
     AND OLD.status IS DISTINCT FROM NEW.status
     AND NOT EXISTS (
       SELECT 1 FROM public.manifest_receipts r
       WHERE r.manifest_id=NEW.id AND r.company_id=NEW.company_id
     )
  THEN
    RAISE EXCEPTION 'No se puede recibir el manifiesto sin conciliación de todas las encomiendas';
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS manifests_require_receipt_before_received ON public.manifests;
CREATE TRIGGER manifests_require_receipt_before_received
BEFORE UPDATE OF status ON public.manifests
FOR EACH ROW
EXECUTE FUNCTION private.require_manifest_receipt_before_received();
