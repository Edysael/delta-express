-- Atomic creation of a route, manifest, manifest links and shipment dispatch.
-- SECURITY INVOKER is intentional: existing RLS policies remain authoritative.
CREATE OR REPLACE FUNCTION public.create_trip_with_manifest(
  p_company_id uuid,
  p_route_code text,
  p_route_name text,
  p_origin_branch_id uuid,
  p_destination_branch_id uuid,
  p_planned_departure timestamptz,
  p_planned_arrival timestamptz,
  p_driver_id uuid,
  p_vehicle_id uuid,
  p_manifest_number text,
  p_shipment_ids uuid[]
)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path TO ''
AS $function$
DECLARE
  v_user uuid := auth.uid();
  v_route_id uuid;
  v_manifest_id uuid;
  v_expected integer;
  v_updated integer;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'Debe iniciar sesión'; END IF;
  IF p_company_id IS NULL OR NOT (
    private.is_company_admin(p_company_id)
    OR private.can_access_branch(p_company_id,p_origin_branch_id)
  ) THEN
    RAISE EXCEPTION 'No tiene permisos para crear viajes en esta empresa y sucursal';
  END IF;
  IF p_origin_branch_id IS NULL OR p_destination_branch_id IS NULL
     OR p_origin_branch_id=p_destination_branch_id THEN
    RAISE EXCEPTION 'Origen y destino deben ser sucursales distintas';
  END IF;
  IF p_planned_departure IS NULL OR p_planned_arrival IS NULL
     OR p_planned_arrival<=p_planned_departure THEN
    RAISE EXCEPTION 'La fecha estimada de llegada debe ser posterior a la salida';
  END IF;
  IF coalesce(trim(p_route_code),'')='' OR coalesce(trim(p_route_name),'')=''
     OR coalesce(trim(p_manifest_number),'')='' THEN
    RAISE EXCEPTION 'Faltan códigos o nombres de ruta/manifiesto';
  END IF;
  IF p_shipment_ids IS NULL OR cardinality(p_shipment_ids)=0 THEN
    RAISE EXCEPTION 'Debe seleccionar al menos una encomienda';
  END IF;
  IF cardinality(p_shipment_ids)<>(SELECT count(DISTINCT x) FROM unnest(p_shipment_ids) x) THEN
    RAISE EXCEPTION 'La selección contiene encomiendas duplicadas';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.branches b WHERE b.id=p_origin_branch_id AND b.company_id=p_company_id AND b.is_active)
     OR NOT EXISTS (SELECT 1 FROM public.branches b WHERE b.id=p_destination_branch_id AND b.company_id=p_company_id AND b.is_active) THEN
    RAISE EXCEPTION 'Las sucursales no existen, no están activas o no pertenecen a la empresa';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.drivers d WHERE d.id=p_driver_id AND d.company_id=p_company_id AND d.status='active') THEN
    RAISE EXCEPTION 'El conductor no está activo en esta empresa';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.vehicles v WHERE v.id=p_vehicle_id AND v.company_id=p_company_id AND v.status='available') THEN
    RAISE EXCEPTION 'El vehículo no está disponible en esta empresa';
  END IF;

  PERFORM 1 FROM public.shipments s
  WHERE s.id=ANY(p_shipment_ids)
  ORDER BY s.id
  FOR UPDATE;
  SELECT count(*) INTO v_expected
  FROM public.shipments s
  WHERE s.id=ANY(p_shipment_ids)
    AND s.company_id=p_company_id
    AND s.origin_branch_id=p_origin_branch_id
    AND s.destination_branch_id=p_destination_branch_id
    AND s.status='sorting'
    AND (private.is_company_admin(p_company_id) OR private.can_access_shipment(p_company_id,s.id));
  IF v_expected<>cardinality(p_shipment_ids) THEN
    RAISE EXCEPTION 'Todas las encomiendas deben pertenecer a la empresa, coincidir con la ruta, estar en clasificación y ser accesibles';
  END IF;

  INSERT INTO public.routes(company_id,code,name,origin_branch_id,destination_branch_id,planned_departure,planned_arrival,status,created_by)
  VALUES(p_company_id,p_route_code,p_route_name,p_origin_branch_id,p_destination_branch_id,p_planned_departure,p_planned_arrival,'planned',v_user)
  RETURNING id INTO v_route_id;

  INSERT INTO public.manifests(company_id,manifest_number,route_id,vehicle_id,driver_id,origin_branch_id,destination_branch_id,status,created_by)
  VALUES(p_company_id,p_manifest_number,v_route_id,p_vehicle_id,p_driver_id,p_origin_branch_id,p_destination_branch_id,'draft',v_user)
  RETURNING id INTO v_manifest_id;

  INSERT INTO public.manifest_shipments(company_id,manifest_id,shipment_id)
  SELECT p_company_id,v_manifest_id,x FROM unnest(p_shipment_ids) x;

  UPDATE public.shipments
  SET status='dispatched',updated_at=now()
  WHERE id=ANY(p_shipment_ids) AND company_id=p_company_id AND status='sorting';
  GET DIAGNOSTICS v_updated=ROW_COUNT;
  IF v_updated<>cardinality(p_shipment_ids) THEN
    RAISE EXCEPTION 'No se pudieron despachar todas las encomiendas; operación cancelada';
  END IF;

  RETURN jsonb_build_object('route_id',v_route_id,'manifest_id',v_manifest_id,'shipment_count',v_updated);
END;
$function$;

REVOKE ALL ON FUNCTION public.create_trip_with_manifest(uuid,text,text,uuid,uuid,timestamptz,timestamptz,uuid,uuid,text,uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_trip_with_manifest(uuid,text,text,uuid,uuid,timestamptz,timestamptz,uuid,uuid,text,uuid[]) TO authenticated;
