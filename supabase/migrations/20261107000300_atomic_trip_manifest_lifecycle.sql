-- Keep trip and manifest lifecycle changes in one transaction.
-- SECURITY INVOKER preserves the existing RLS authorization model.
CREATE OR REPLACE FUNCTION public.transition_trip_manifest(
  p_company_id uuid,
  p_manifest_id uuid,
  p_route_id uuid,
  p_next_manifest_status text
)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path TO ''
AS $function$
DECLARE
  v_user uuid := auth.uid();
  v_manifest public.manifests%ROWTYPE;
  v_route public.routes%ROWTYPE;
  v_next_route_status text;
  v_now timestamptz := now();
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'Debe iniciar sesión';
  END IF;
  IF p_company_id IS NULL OR p_manifest_id IS NULL OR p_route_id IS NULL THEN
    RAISE EXCEPTION 'Faltan identificadores del viaje';
  END IF;
  IF NOT (private.is_company_admin(p_company_id)
      OR EXISTS (
        SELECT 1 FROM public.manifests m
        WHERE m.id=p_manifest_id AND m.company_id=p_company_id
          AND (private.can_access_branch(p_company_id,m.origin_branch_id)
               OR private.can_access_branch(p_company_id,m.destination_branch_id))
      )) THEN
    RAISE EXCEPTION 'No tiene permisos para administrar este viaje';
  END IF;

  SELECT * INTO v_manifest
  FROM public.manifests
  WHERE id=p_manifest_id AND company_id=p_company_id AND route_id=p_route_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No se encontró el manifiesto asociado a esta ruta';
  END IF;

  SELECT * INTO v_route
  FROM public.routes
  WHERE id=p_route_id AND company_id=p_company_id
    AND origin_branch_id=v_manifest.origin_branch_id
    AND destination_branch_id=v_manifest.destination_branch_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'La ruta no coincide con el manifiesto';
  END IF;

  IF NOT (private.is_company_admin(p_company_id)
      OR private.can_access_branch(p_company_id,v_manifest.origin_branch_id)
      OR private.can_access_branch(p_company_id,v_manifest.destination_branch_id)) THEN
    RAISE EXCEPTION 'No tiene acceso a las sucursales del viaje';
  END IF;

  CASE p_next_manifest_status
    WHEN 'sealed' THEN
      IF v_manifest.status<>'draft' OR v_route.status<>'planned' THEN
        RAISE EXCEPTION 'Solo se puede sellar un manifiesto en borrador con ruta programada';
      END IF;
      v_next_route_status := 'ready';
      UPDATE public.manifests SET status='sealed', sealed_at=v_now
      WHERE id=p_manifest_id AND company_id=p_company_id AND status='draft';
    WHEN 'dispatched' THEN
      IF v_manifest.status<>'sealed' OR v_route.status<>'ready' THEN
        RAISE EXCEPTION 'Solo se puede despachar un manifiesto sellado con ruta lista';
      END IF;
      v_next_route_status := 'in_progress';
      UPDATE public.manifests SET status='dispatched', dispatched_at=v_now
      WHERE id=p_manifest_id AND company_id=p_company_id AND status='sealed';
    WHEN 'cancelled' THEN
      IF v_manifest.status NOT IN ('draft','sealed') OR v_route.status NOT IN ('planned','ready') THEN
        RAISE EXCEPTION 'Este viaje ya no se puede cancelar desde su estado actual';
      END IF;
      v_next_route_status := 'cancelled';
      UPDATE public.manifests SET status='cancelled'
      WHERE id=p_manifest_id AND company_id=p_company_id AND status=v_manifest.status;
    ELSE
      RAISE EXCEPTION 'Estado solicitado no permitido';
  END CASE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'El manifiesto cambió durante la operación';
  END IF;

  UPDATE public.routes
  SET status=v_next_route_status,
      actual_departure=CASE WHEN v_next_route_status='in_progress' THEN v_now ELSE actual_departure END,
      updated_at=v_now
  WHERE id=p_route_id AND company_id=p_company_id AND status=v_route.status;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'La ruta no se pudo actualizar; operación revertida';
  END IF;

  RETURN jsonb_build_object(
    'manifest_id',p_manifest_id,
    'manifest_status',p_next_manifest_status,
    'route_id',p_route_id,
    'route_status',v_next_route_status
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.transition_trip_manifest(uuid,uuid,uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.transition_trip_manifest(uuid,uuid,uuid,text) TO authenticated;
