-- Transactional delivery attempt, retry scheduling and physical return.
-- SECURITY INVOKER intentionally keeps RLS as the authorization boundary.
CREATE OR REPLACE FUNCTION public.record_delivery_failure(
  p_company_id uuid,p_shipment_id uuid,p_driver_id uuid,p_branch_id uuid,
  p_failure_reason text,p_notes text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SET search_path TO ''
AS $function$
DECLARE v_user uuid:=auth.uid(); v_shipment public.shipments%ROWTYPE;
 v_attempt integer; v_delivery public.deliveries%ROWTYPE;
BEGIN
 IF v_user IS NULL THEN RAISE EXCEPTION 'Debe iniciar sesión'; END IF;
 IF p_failure_reason IS NULL OR p_failure_reason NOT IN ('recipient_absent','address_not_found','recipient_rejected','access_blocked','incorrect_address','other') THEN
  RAISE EXCEPTION 'Motivo de fallo no válido';
 END IF;
 IF NOT EXISTS(SELECT 1 FROM public.drivers d WHERE d.id=p_driver_id AND d.company_id=p_company_id AND d.user_id=v_user AND d.status='active') THEN
  RAISE EXCEPTION 'El conductor autenticado no coincide con el conductor asignado';
 END IF;
 SELECT * INTO v_shipment FROM public.shipments
 WHERE id=p_shipment_id AND company_id=p_company_id FOR UPDATE;
 IF NOT FOUND OR v_shipment.status<>'out_for_delivery' THEN
  RAISE EXCEPTION 'La encomienda no está En reparto o no existe';
 END IF;
 IF p_branch_id IS NOT NULL AND p_branch_id<>v_shipment.destination_branch_id THEN
  RAISE EXCEPTION 'La sucursal del intento no coincide con el destino';
 END IF;
 IF NOT private.can_access_shipment(p_company_id,p_shipment_id) THEN
  RAISE EXCEPTION 'No tiene acceso a esta encomienda';
 END IF;
 SELECT COALESCE(MAX(attempt_number),0)+1 INTO v_attempt
 FROM public.deliveries WHERE company_id=p_company_id AND shipment_id=p_shipment_id;
 INSERT INTO public.deliveries(company_id,shipment_id,driver_id,branch_id,attempt_number,status,failure_reason,notes)
 VALUES(p_company_id,p_shipment_id,p_driver_id,p_branch_id,v_attempt,'failed',p_failure_reason,NULLIF(btrim(p_notes),''))
 RETURNING * INTO v_delivery;
 UPDATE public.shipments SET status='delivery_failed',updated_at=now()
 WHERE id=p_shipment_id AND company_id=p_company_id AND status='out_for_delivery';
 IF NOT FOUND THEN RAISE EXCEPTION 'No se pudo cambiar el estado de la encomienda'; END IF;
 RETURN jsonb_build_object('delivery_id',v_delivery.id,'attempt_number',v_attempt,'shipment_status','delivery_failed');
END;
$function$;

CREATE OR REPLACE FUNCTION public.reschedule_delivery_attempt(
 p_company_id uuid,p_delivery_id uuid,p_driver_id uuid,p_next_attempt_at timestamptz,p_notes text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SET search_path TO ''
AS $function$
DECLARE v_user uuid:=auth.uid(); v_delivery public.deliveries%ROWTYPE;
BEGIN
 IF v_user IS NULL THEN RAISE EXCEPTION 'Debe iniciar sesión'; END IF;
 IF p_next_attempt_at IS NULL OR p_next_attempt_at<=now() THEN RAISE EXCEPTION 'La nueva visita debe ser futura'; END IF;
 SELECT * INTO v_delivery FROM public.deliveries
 WHERE id=p_delivery_id AND company_id=p_company_id FOR UPDATE;
 IF NOT FOUND OR v_delivery.status<>'failed' THEN RAISE EXCEPTION 'El intento ya no está fallido o no existe'; END IF;
 IF NOT (private.is_company_admin(p_company_id) OR private.can_access_branch(p_company_id,v_delivery.branch_id)
   OR private.can_access_shipment(p_company_id,v_delivery.shipment_id)) THEN
  RAISE EXCEPTION 'No tiene permisos para reprogramar este intento';
 END IF;
 IF NOT EXISTS(SELECT 1 FROM public.drivers d WHERE d.id=p_driver_id AND d.company_id=p_company_id AND d.status='active') THEN
  RAISE EXCEPTION 'El conductor seleccionado no está activo en esta empresa';
 END IF;
 UPDATE public.deliveries SET status='rescheduled',driver_id=p_driver_id,
  next_attempt_at=p_next_attempt_at,rescheduled_at=now(),rescheduled_by=v_user,
  notes=NULLIF(btrim(p_notes),''),updated_at=now()
 WHERE id=p_delivery_id AND company_id=p_company_id AND status='failed';
 IF NOT FOUND THEN RAISE EXCEPTION 'No se pudo reprogramar el intento'; END IF;
 RETURN jsonb_build_object('delivery_id',p_delivery_id,'status','rescheduled','next_attempt_at',p_next_attempt_at);
END;
$function$;

CREATE OR REPLACE FUNCTION public.confirm_delivery_return_to_branch(
 p_company_id uuid,p_delivery_id uuid,p_notes text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SET search_path TO ''
AS $function$
DECLARE v_user uuid:=auth.uid(); v_delivery public.deliveries%ROWTYPE;
 v_shipment public.shipments%ROWTYPE; v_failed_count integer;
BEGIN
 IF v_user IS NULL THEN RAISE EXCEPTION 'Debe iniciar sesión'; END IF;
 SELECT * INTO v_delivery FROM public.deliveries
 WHERE id=p_delivery_id AND company_id=p_company_id FOR UPDATE;
 IF NOT FOUND OR v_delivery.status NOT IN ('failed','rescheduled') THEN
  RAISE EXCEPTION 'El intento no está pendiente de retorno';
 END IF;
 IF NOT (private.is_company_admin(p_company_id) OR private.can_access_branch(p_company_id,v_delivery.branch_id)
   OR private.can_access_shipment(p_company_id,v_delivery.shipment_id)) THEN
  RAISE EXCEPTION 'No tiene permisos para confirmar el retorno';
 END IF;
 SELECT * INTO v_shipment FROM public.shipments
 WHERE id=v_delivery.shipment_id AND company_id=p_company_id FOR UPDATE;
 IF NOT FOUND OR v_shipment.status<>'delivery_failed' THEN
  RAISE EXCEPTION 'La encomienda no está en estado de entrega fallida';
 END IF;
 SELECT count(*) INTO v_failed_count FROM public.deliveries
 WHERE company_id=p_company_id AND shipment_id=v_delivery.shipment_id
 AND status IN ('failed','rescheduled','returned');
 IF v_failed_count<2 THEN RAISE EXCEPTION 'Se requieren al menos dos intentos de entrega fallidos'; END IF;
 UPDATE public.deliveries SET status='returned',next_attempt_at=NULL,
  notes=COALESCE(NULLIF(btrim(p_notes),''),'Retorno recibido físicamente en sucursal'),updated_at=now()
 WHERE id=p_delivery_id AND company_id=p_company_id;
 UPDATE public.shipments SET status='returned',updated_at=now()
 WHERE id=v_shipment.id AND company_id=p_company_id AND status='delivery_failed';
 IF NOT FOUND THEN RAISE EXCEPTION 'No se pudo actualizar el estado de la encomienda'; END IF;
 INSERT INTO public.shipment_events(company_id,shipment_id,event_type,previous_status,new_status,
  description,branch_id,location_text,created_by,event_data)
 VALUES(p_company_id,v_shipment.id,'delivery_returned_to_branch','delivery_failed','returned',
  'Retorno físico de encomienda recibido en sucursal',v_delivery.branch_id,
  'Sucursal de destino',v_user,jsonb_build_object('delivery_id',p_delivery_id,'notes',p_notes));
 RETURN jsonb_build_object('delivery_id',p_delivery_id,'shipment_id',v_shipment.id,'shipment_status','returned');
END;
$function$;

REVOKE ALL ON FUNCTION public.record_delivery_failure(uuid,uuid,uuid,uuid,text,text) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.reschedule_delivery_attempt(uuid,uuid,uuid,timestamptz,text) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.confirm_delivery_return_to_branch(uuid,uuid,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.record_delivery_failure(uuid,uuid,uuid,uuid,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.reschedule_delivery_attempt(uuid,uuid,uuid,timestamptz,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.confirm_delivery_return_to_branch(uuid,uuid,text) TO authenticated;
