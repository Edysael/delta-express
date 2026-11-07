-- Partial deliveries are recorded as immutable delivery attempts.
-- The shipment remains out_for_delivery until the cumulative delivered quantity
-- reaches shipments.pieces; only then is it transitioned to delivered.
ALTER TABLE public.deliveries
  ADD COLUMN IF NOT EXISTS pieces_delivered integer,
  ADD COLUMN IF NOT EXISTS pieces_remaining integer;

ALTER TABLE public.deliveries
  ADD CONSTRAINT deliveries_partial_quantities_valid
  CHECK (
    (pieces_delivered IS NULL AND pieces_remaining IS NULL)
    OR (pieces_delivered > 0 AND pieces_remaining >= 0)
  );

CREATE OR REPLACE FUNCTION public.record_partial_delivery(
 p_company_id uuid,
 p_shipment_id uuid,
 p_delivery_id uuid,
 p_driver_id uuid,
 p_branch_id uuid,
 p_pieces_delivered integer,
 p_recipient_name text,
 p_recipient_document text DEFAULT NULL,
 p_notes text DEFAULT NULL,
 p_evidence jsonb DEFAULT '[]'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SET search_path TO ''
AS $function$
DECLARE
 v_user uuid:=auth.uid();
 v_shipment public.shipments%ROWTYPE;
 v_prior integer;
 v_remaining integer;
 v_attempt integer;
 v_item jsonb;
 v_kind text;
 v_path text;
 v_count integer:=0;
 v_status text;
BEGIN
 IF v_user IS NULL THEN RAISE EXCEPTION 'Debe iniciar sesión'; END IF;
 IF p_company_id IS NULL OR p_shipment_id IS NULL OR p_delivery_id IS NULL
   OR p_driver_id IS NULL OR p_pieces_delivered IS NULL OR p_pieces_delivered<=0
   OR NULLIF(btrim(p_recipient_name),'') IS NULL THEN
  RAISE EXCEPTION 'Datos obligatorios de entrega parcial incompletos';
 END IF;
 IF jsonb_typeof(COALESCE(p_evidence,'[]'::jsonb))<>'array' THEN
  RAISE EXCEPTION 'Formato de evidencias no válido';
 END IF;
 IF NOT EXISTS(SELECT 1 FROM public.drivers d WHERE d.id=p_driver_id
   AND d.company_id=p_company_id AND d.user_id=v_user AND d.status='active') THEN
  RAISE EXCEPTION 'El conductor autenticado no coincide con el conductor activo';
 END IF;
 SELECT * INTO v_shipment FROM public.shipments
 WHERE id=p_shipment_id AND company_id=p_company_id FOR UPDATE;
 IF NOT FOUND OR v_shipment.status<>'out_for_delivery' THEN
  RAISE EXCEPTION 'La encomienda no está En reparto';
 END IF;
 IF p_branch_id IS NOT NULL AND p_branch_id<>v_shipment.destination_branch_id THEN
  RAISE EXCEPTION 'La sucursal no coincide con el destino';
 END IF;
 IF NOT private.can_access_shipment(p_company_id,p_shipment_id) THEN
  RAISE EXCEPTION 'No tiene acceso a esta encomienda';
 END IF;
 SELECT COALESCE(sum(pieces_delivered),0) INTO v_prior
 FROM public.deliveries WHERE company_id=p_company_id AND shipment_id=p_shipment_id
  AND status='partial' AND pieces_delivered IS NOT NULL;
 v_remaining:=v_shipment.pieces-v_prior;
 IF v_remaining<=0 OR p_pieces_delivered>=v_remaining THEN
  RAISE EXCEPTION 'La cantidad parcial debe ser menor que las piezas pendientes (%). Para completar la entrega use Confirmar entrega.',v_remaining;
 END IF;
 FOR v_item IN SELECT value FROM jsonb_array_elements(COALESCE(p_evidence,'[]'::jsonb))
 LOOP
  v_kind:=v_item->>'evidence_type';v_path:=v_item->>'storage_path';
  IF v_kind IS NULL OR v_kind NOT IN ('signature','photo') OR v_path IS NULL
    OR v_path NOT LIKE p_company_id::text||'/'||p_shipment_id::text||'/'||p_delivery_id::text||'/%' THEN
   RAISE EXCEPTION 'La ruta o tipo de evidencia no es válido';
  END IF;
  v_count:=v_count+1;
 END LOOP;
 IF v_count>2 OR v_count<>(SELECT count(DISTINCT value->>'evidence_type') FROM jsonb_array_elements(COALESCE(p_evidence,'[]'::jsonb))) THEN
  RAISE EXCEPTION 'Evidencias duplicadas o cantidad no permitida';
 END IF;
 SELECT COALESCE(MAX(attempt_number),0)+1 INTO v_attempt FROM public.deliveries
 WHERE company_id=p_company_id AND shipment_id=p_shipment_id;
 INSERT INTO public.deliveries(id,company_id,shipment_id,driver_id,branch_id,attempt_number,
  status,recipient_name,recipient_document,delivered_at,notes,pieces_delivered,pieces_remaining)
 VALUES(p_delivery_id,p_company_id,p_shipment_id,p_driver_id,p_branch_id,v_attempt,
  'partial',btrim(p_recipient_name),NULLIF(btrim(p_recipient_document),''),now(),
  NULLIF(btrim(p_notes),''),p_pieces_delivered,v_remaining-p_pieces_delivered);
 INSERT INTO public.delivery_evidence(company_id,delivery_id,evidence_type,storage_path,description,captured_by,metadata)
 SELECT p_company_id,p_delivery_id,e.value->>'evidence_type',e.value->>'storage_path',
  NULLIF(e.value->>'description',''),v_user,COALESCE(e.value->'metadata','{}'::jsonb)
 FROM jsonb_array_elements(COALESCE(p_evidence,'[]'::jsonb)) e;
 INSERT INTO public.shipment_events(company_id,shipment_id,event_type,previous_status,new_status,
  description,branch_id,location_text,created_by,event_data)
 VALUES(p_company_id,p_shipment_id,'partial_delivery','out_for_delivery','out_for_delivery',
  'Entrega parcial: '||p_pieces_delivered||' de '||v_shipment.pieces||' piezas entregadas',
  p_branch_id,'Dirección de entrega',v_user,
  jsonb_build_object('delivery_id',p_delivery_id,'pieces_delivered',p_pieces_delivered,
   'pieces_remaining',v_remaining-p_pieces_delivered));
 RETURN jsonb_build_object('delivery_id',p_delivery_id,'shipment_id',p_shipment_id,
  'status','partial','pieces_delivered',p_pieces_delivered,
  'pieces_total',v_shipment.pieces,'pieces_remaining',v_remaining-p_pieces_delivered,
  'attempt_number',v_attempt);
END;
$function$;

REVOKE ALL ON FUNCTION public.record_partial_delivery(uuid,uuid,uuid,uuid,uuid,integer,text,text,text,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.record_partial_delivery(uuid,uuid,uuid,uuid,uuid,integer,text,text,text,jsonb) TO authenticated;
