-- Atomic, authenticated driver workflow for failed delivery attempts.
CREATE OR REPLACE FUNCTION public.record_delivery_failure(
  p_company_id uuid,
  p_shipment_id uuid,
  p_driver_id uuid,
  p_branch_id uuid,
  p_failure_reason text,
  p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_user uuid := auth.uid();
  v_shipment public.shipments%ROWTYPE;
  v_driver public.drivers%ROWTYPE;
  v_manifest_id uuid;
  v_attempt integer;
  v_delivery_id uuid;
  v_allowed_reasons text[] := ARRAY[
    'recipient_absent','address_not_found','recipient_rejected',
    'access_blocked','incorrect_address','other'
  ];
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'Debe iniciar sesión'; END IF;
  IF p_company_id IS NULL OR p_shipment_id IS NULL OR p_driver_id IS NULL THEN
    RAISE EXCEPTION 'Faltan datos obligatorios del intento';
  END IF;
  IF NOT (p_failure_reason = ANY(v_allowed_reasons)) THEN
    RAISE EXCEPTION 'Motivo de entrega fallida no válido';
  END IF;
  IF p_notes IS NOT NULL AND length(p_notes)>2000 THEN
    RAISE EXCEPTION 'Las observaciones superan el máximo permitido';
  END IF;

  SELECT * INTO v_driver
  FROM public.drivers
  WHERE id=p_driver_id AND company_id=p_company_id AND user_id=v_user AND status='active'
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'El conductor no está activo o no corresponde al usuario autenticado'; END IF;

  SELECT s.* INTO v_shipment
  FROM public.shipments s
  WHERE s.id=p_shipment_id AND s.company_id=p_company_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No se encontró la encomienda'; END IF;
  IF v_shipment.status<>'out_for_delivery' THEN
    RAISE EXCEPTION 'La encomienda no está en reparto';
  END IF;
  IF p_branch_id IS NOT NULL AND p_branch_id<>v_shipment.destination_branch_id THEN
    RAISE EXCEPTION 'La sucursal informada no corresponde al destino de la encomienda';
  END IF;

  SELECT m.id INTO v_manifest_id
  FROM public.manifests m
  JOIN public.manifest_shipments ms
    ON ms.manifest_id=m.id AND ms.company_id=m.company_id
  WHERE m.company_id=p_company_id
    AND m.driver_id=p_driver_id
    AND m.status='dispatched'
    AND ms.shipment_id=p_shipment_id
  ORDER BY m.dispatched_at DESC NULLS LAST
  LIMIT 1
  FOR UPDATE OF m;
  IF v_manifest_id IS NULL THEN
    RAISE EXCEPTION 'La encomienda no está asignada a un manifiesto activo de este conductor';
  END IF;

  SELECT COALESCE(MAX(d.attempt_number),0)+1 INTO v_attempt
  FROM public.deliveries d
  WHERE d.company_id=p_company_id AND d.shipment_id=p_shipment_id;

  INSERT INTO public.deliveries(
    company_id,shipment_id,driver_id,branch_id,attempt_number,status,
    failure_reason,notes
  ) VALUES (
    p_company_id,p_shipment_id,p_driver_id,v_shipment.destination_branch_id,
    v_attempt,'failed',p_failure_reason,NULLIF(btrim(p_notes),'')
  ) RETURNING id INTO v_delivery_id;

  UPDATE public.shipments
  SET status='delivery_failed',updated_at=now()
  WHERE id=p_shipment_id AND company_id=p_company_id AND status='out_for_delivery';
  IF NOT FOUND THEN RAISE EXCEPTION 'No se pudo confirmar el estado de la encomienda'; END IF;

  INSERT INTO public.shipment_events(
    company_id,shipment_id,event_type,previous_status,new_status,
    description,branch_id,location_text,created_by,event_data
  ) VALUES (
    p_company_id,p_shipment_id,'delivery_attempt_failed','out_for_delivery',
    'delivery_failed','Intento de entrega fallido: '||p_failure_reason,
    v_shipment.destination_branch_id,NULL,v_user,
    jsonb_build_object('delivery_id',v_delivery_id,'attempt_number',v_attempt,
      'failure_reason',p_failure_reason,'notes',NULLIF(btrim(p_notes),''))
  );

  RETURN jsonb_build_object(
    'delivery_id',v_delivery_id,'attempt_number',v_attempt,
    'shipment_id',p_shipment_id,'shipment_status','delivery_failed'
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.record_delivery_failure(uuid,uuid,uuid,uuid,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_delivery_failure(uuid,uuid,uuid,uuid,text,text) TO authenticated;
