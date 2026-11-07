-- Atomic delivery confirmation after private evidence uploads.
-- The client uploads objects first using a client-generated UUID; this RPC
-- commits the delivery, evidence metadata, shipment status and timeline event.
CREATE OR REPLACE FUNCTION public.confirm_delivery_with_evidence(
 p_company_id uuid,
 p_shipment_id uuid,
 p_delivery_id uuid,
 p_driver_id uuid,
 p_branch_id uuid,
 p_recipient_name text,
 p_recipient_document text,
 p_notes text,
 p_evidence jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SET search_path TO ''
AS $function$
DECLARE
 v_user uuid:=auth.uid();
 v_shipment public.shipments%ROWTYPE;
 v_existing public.deliveries%ROWTYPE;
 v_attempt integer;
 v_item jsonb;
 v_kind text;
 v_path text;
 v_count integer:=0;
BEGIN
 IF v_user IS NULL THEN RAISE EXCEPTION 'Debe iniciar sesión'; END IF;
 IF p_company_id IS NULL OR p_shipment_id IS NULL OR p_delivery_id IS NULL
   OR p_driver_id IS NULL OR NULLIF(btrim(p_recipient_name),'') IS NULL THEN
  RAISE EXCEPTION 'Faltan datos obligatorios de la entrega';
 END IF;
 IF jsonb_typeof(COALESCE(p_evidence,'[]'::jsonb))<>'array' THEN
  RAISE EXCEPTION 'Formato de evidencias no válido';
 END IF;
 IF NOT EXISTS(SELECT 1 FROM public.drivers d
  WHERE d.id=p_driver_id AND d.company_id=p_company_id AND d.user_id=v_user) THEN
  RAISE EXCEPTION 'El conductor autenticado no coincide con el conductor asignado';
 END IF;
 SELECT * INTO v_shipment FROM public.shipments
 WHERE id=p_shipment_id AND company_id=p_company_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'No se encontró la encomienda'; END IF;

 SELECT * INTO v_existing FROM public.deliveries
 WHERE id=p_delivery_id AND company_id=p_company_id;
 IF FOUND THEN
  IF v_existing.shipment_id=p_shipment_id AND v_existing.status='delivered'
    AND v_shipment.status='delivered' THEN
   RETURN jsonb_build_object('delivery_id',p_delivery_id,'shipment_id',p_shipment_id,'status','delivered','idempotent',true);
  END IF;
  RAISE EXCEPTION 'El identificador de entrega ya fue utilizado';
 END IF;
 IF v_shipment.status<>'out_for_delivery' THEN
  RAISE EXCEPTION 'La encomienda ya no está En reparto';
 END IF;
 IF p_branch_id IS NOT NULL AND p_branch_id<>v_shipment.destination_branch_id THEN
  RAISE EXCEPTION 'La sucursal no coincide con el destino de la encomienda';
 END IF;
 IF NOT private.can_access_shipment(p_company_id,p_shipment_id) THEN
  RAISE EXCEPTION 'No tiene acceso a esta encomienda';
 END IF;

 FOR v_item IN SELECT value FROM jsonb_array_elements(COALESCE(p_evidence,'[]'::jsonb))
 LOOP
  v_kind:=v_item->>'evidence_type';
  v_path:=v_item->>'storage_path';
  IF v_kind NOT IN ('signature','photo') OR v_path IS NULL
    OR v_path NOT LIKE p_company_id::text||'/'||p_shipment_id::text||'/'||p_delivery_id::text||'/%' THEN
   RAISE EXCEPTION 'La ruta o tipo de evidencia no es válido';
  END IF;
  v_count:=v_count+1;
 END LOOP;
 IF v_count>2 THEN RAISE EXCEPTION 'La entrega admite como máximo dos evidencias'; END IF;

 SELECT COALESCE(MAX(attempt_number),0)+1 INTO v_attempt
 FROM public.deliveries WHERE company_id=p_company_id AND shipment_id=p_shipment_id;
 INSERT INTO public.deliveries(id,company_id,shipment_id,driver_id,branch_id,attempt_number,
  status,recipient_name,recipient_document,delivered_at,notes)
 VALUES(p_delivery_id,p_company_id,p_shipment_id,p_driver_id,p_branch_id,v_attempt,
  'delivered',btrim(p_recipient_name),NULLIF(btrim(p_recipient_document),''),now(),NULLIF(btrim(p_notes),''));

 INSERT INTO public.delivery_evidence(company_id,delivery_id,evidence_type,storage_path,description,captured_by,metadata)
 SELECT p_company_id,p_delivery_id,e.value->>'evidence_type',e.value->>'storage_path',
  NULLIF(e.value->>'description',''),v_user,COALESCE(e.value->'metadata','{}'::jsonb)
 FROM jsonb_array_elements(COALESCE(p_evidence,'[]'::jsonb)) e;

 UPDATE public.shipments SET status='delivered',delivered_at=now(),updated_at=now()
 WHERE id=p_shipment_id AND company_id=p_company_id AND status='out_for_delivery';
 IF NOT FOUND THEN RAISE EXCEPTION 'No se pudo confirmar el estado final de la encomienda'; END IF;

 INSERT INTO public.shipment_events(company_id,shipment_id,event_type,previous_status,new_status,
  description,branch_id,location_text,created_by,event_data)
 VALUES(p_company_id,p_shipment_id,'delivery_completed','out_for_delivery','delivered',
  'Entrega confirmada a '||btrim(p_recipient_name),p_branch_id,
  'Dirección de entrega',v_user,jsonb_build_object('delivery_id',p_delivery_id,'evidence_count',v_count));

 RETURN jsonb_build_object('delivery_id',p_delivery_id,'shipment_id',p_shipment_id,
  'status','delivered','attempt_number',v_attempt,'evidence_count',v_count,'idempotent',false);
END;
$function$;

REVOKE ALL ON FUNCTION public.confirm_delivery_with_evidence(uuid,uuid,uuid,uuid,uuid,text,text,text,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.confirm_delivery_with_evidence(uuid,uuid,uuid,uuid,uuid,text,text,text,jsonb) TO authenticated;
