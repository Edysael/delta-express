-- Complete the retry and physical-return RPCs used by the transport interface.
CREATE OR REPLACE FUNCTION public.reschedule_delivery_attempt(
  p_company_id uuid,
  p_delivery_id uuid,
  p_driver_id uuid,
  p_next_attempt_at timestamptz,
  p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_user uuid := auth.uid();
  v_delivery public.deliveries%ROWTYPE;
  v_shipment public.shipments%ROWTYPE;
  v_driver public.drivers%ROWTYPE;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'Debe iniciar sesión'; END IF;
  IF p_company_id IS NULL OR p_delivery_id IS NULL OR p_driver_id IS NULL OR p_next_attempt_at IS NULL THEN
    RAISE EXCEPTION 'Faltan datos para reprogramar la visita';
  END IF;
  IF p_next_attempt_at <= now() THEN RAISE EXCEPTION 'La nueva visita debe ser futura'; END IF;
  IF p_next_attempt_at > now() + interval '90 days' THEN RAISE EXCEPTION 'La reprogramación no puede superar 90 días'; END IF;
  IF p_notes IS NOT NULL AND length(p_notes)>2000 THEN RAISE EXCEPTION 'Las observaciones superan el máximo permitido'; END IF;

  SELECT * INTO v_delivery FROM public.deliveries
  WHERE id=p_delivery_id AND company_id=p_company_id FOR UPDATE;
  IF NOT FOUND OR v_delivery.status<>'failed' THEN
    RAISE EXCEPTION 'Solo se puede reprogramar un intento fallido';
  END IF;
  SELECT * INTO v_shipment FROM public.shipments
  WHERE id=v_delivery.shipment_id AND company_id=p_company_id FOR UPDATE;
  IF NOT FOUND OR v_shipment.status<>'delivery_failed' THEN
    RAISE EXCEPTION 'La encomienda no está pendiente de reintento';
  END IF;
  IF NOT (private.is_company_admin(p_company_id)
      OR private.can_access_branch(p_company_id,v_shipment.origin_branch_id)
      OR private.can_access_branch(p_company_id,v_shipment.destination_branch_id)) THEN
    RAISE EXCEPTION 'No tiene permisos para reprogramar esta encomienda';
  END IF;
  SELECT * INTO v_driver FROM public.drivers
  WHERE id=p_driver_id AND company_id=p_company_id AND status='active';
  IF NOT FOUND THEN RAISE EXCEPTION 'El conductor seleccionado no está activo en esta empresa'; END IF;

  UPDATE public.deliveries
  SET status='rescheduled',driver_id=p_driver_id,next_attempt_at=p_next_attempt_at,
      rescheduled_at=now(),rescheduled_by=v_user,
      notes=COALESCE(NULLIF(btrim(p_notes),''),notes),updated_at=now()
  WHERE id=p_delivery_id AND company_id=p_company_id AND status='failed';
  IF NOT FOUND THEN RAISE EXCEPTION 'El intento cambió durante la reprogramación'; END IF;

  RETURN jsonb_build_object('delivery_id',p_delivery_id,'status','rescheduled',
    'driver_id',p_driver_id,'next_attempt_at',p_next_attempt_at);
END;
$function$;

CREATE OR REPLACE FUNCTION public.confirm_delivery_return_to_branch(
  p_company_id uuid,
  p_delivery_id uuid,
  p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_user uuid := auth.uid();
  v_delivery public.deliveries%ROWTYPE;
  v_shipment public.shipments%ROWTYPE;
  v_attempt_count integer;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'Debe iniciar sesión'; END IF;
  IF p_company_id IS NULL OR p_delivery_id IS NULL THEN RAISE EXCEPTION 'Faltan datos del retorno'; END IF;
  IF p_notes IS NOT NULL AND length(p_notes)>2000 THEN RAISE EXCEPTION 'Las observaciones superan el máximo permitido'; END IF;

  SELECT * INTO v_delivery FROM public.deliveries
  WHERE id=p_delivery_id AND company_id=p_company_id FOR UPDATE;
  IF NOT FOUND OR v_delivery.status NOT IN ('failed','rescheduled') THEN
    RAISE EXCEPTION 'El intento no está habilitado para retorno a sucursal';
  END IF;
  SELECT * INTO v_shipment FROM public.shipments
  WHERE id=v_delivery.shipment_id AND company_id=p_company_id FOR UPDATE;
  IF NOT FOUND OR v_shipment.status<>'delivery_failed' THEN
    RAISE EXCEPTION 'La encomienda no está pendiente de retorno';
  END IF;
  IF NOT (private.is_company_admin(p_company_id)
      OR private.can_access_branch(p_company_id,v_shipment.destination_branch_id)) THEN
    RAISE EXCEPTION 'Solo personal autorizado de la sucursal de destino puede confirmar el retorno físico';
  END IF;

  SELECT count(*) INTO v_attempt_count
  FROM public.deliveries d
  WHERE d.company_id=p_company_id AND d.shipment_id=v_shipment.id
    AND d.status IN ('failed','rescheduled');
  IF v_attempt_count<2 THEN
    RAISE EXCEPTION 'Se requieren al menos dos intentos fallidos antes de aceptar el retorno';
  END IF;

  UPDATE public.deliveries
  SET status='returned',next_attempt_at=NULL,
      notes=COALESCE(NULLIF(btrim(p_notes),''),notes),updated_at=now()
  WHERE id=p_delivery_id AND company_id=p_company_id
    AND status IN ('failed','rescheduled');
  IF NOT FOUND THEN RAISE EXCEPTION 'El intento cambió durante la confirmación del retorno'; END IF;

  UPDATE public.shipments
  SET status='returned',updated_at=now()
  WHERE id=v_shipment.id AND company_id=p_company_id AND status='delivery_failed';
  IF NOT FOUND THEN RAISE EXCEPTION 'No se pudo actualizar el estado de la encomienda'; END IF;

  INSERT INTO public.shipment_events(
    company_id,shipment_id,event_type,previous_status,new_status,
    description,branch_id,location_text,created_by,event_data
  ) VALUES (
    p_company_id,v_shipment.id,'delivery_return_received','delivery_failed','returned',
    'Retorno físico recibido en sucursal de destino',
    v_shipment.destination_branch_id,NULL,v_user,
    jsonb_build_object('delivery_id',p_delivery_id,'notes',NULLIF(btrim(p_notes),''),
      'failed_attempts',v_attempt_count)
  );

  RETURN jsonb_build_object('delivery_id',p_delivery_id,
    'shipment_id',v_shipment.id,'shipment_status','returned',
    'failed_attempts',v_attempt_count);
END;
$function$;

REVOKE ALL ON FUNCTION public.reschedule_delivery_attempt(uuid,uuid,uuid,timestamptz,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reschedule_delivery_attempt(uuid,uuid,uuid,timestamptz,text) TO authenticated;
REVOKE ALL ON FUNCTION public.confirm_delivery_return_to_branch(uuid,uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.confirm_delivery_return_to_branch(uuid,uuid,text) TO authenticated;
