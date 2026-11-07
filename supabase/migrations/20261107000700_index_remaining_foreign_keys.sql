-- Cover the remaining foreign-key columns reported by the Supabase advisor.
-- Additive only: no existing index or data is removed.
CREATE INDEX IF NOT EXISTS deliveries_rescheduled_by_idx
  ON public.deliveries (rescheduled_by);
CREATE INDEX IF NOT EXISTS driver_geofence_events_branch_id_idx
  ON public.driver_geofence_events (branch_id);
CREATE INDEX IF NOT EXISTS driver_geofence_events_driver_id_idx
  ON public.driver_geofence_events (driver_id);
CREATE INDEX IF NOT EXISTS driver_location_pings_driver_id_idx
  ON public.driver_location_pings (driver_id);
CREATE INDEX IF NOT EXISTS incident_activity_actor_user_id_idx
  ON public.incident_activity (actor_user_id);
CREATE INDEX IF NOT EXISTS incident_activity_incident_id_idx
  ON public.incident_activity (incident_id);
CREATE INDEX IF NOT EXISTS incident_evidence_incident_id_idx
  ON public.incident_evidence (incident_id);
CREATE INDEX IF NOT EXISTS incident_evidence_shipment_id_idx
  ON public.incident_evidence (shipment_id);
CREATE INDEX IF NOT EXISTS incident_evidence_uploaded_by_idx
  ON public.incident_evidence (uploaded_by);
CREATE INDEX IF NOT EXISTS incident_reviews_incident_id_idx
  ON public.incident_reviews (incident_id);
CREATE INDEX IF NOT EXISTS incident_reviews_reviewer_user_id_idx
  ON public.incident_reviews (reviewer_user_id);
CREATE INDEX IF NOT EXISTS incidents_approved_by_idx
  ON public.incidents (approved_by);
CREATE INDEX IF NOT EXISTS manifest_receipt_items_receipt_company_idx
  ON public.manifest_receipt_items (receipt_id, company_id);
CREATE INDEX IF NOT EXISTS manifest_receipt_items_shipment_id_idx
  ON public.manifest_receipt_items (shipment_id);
CREATE INDEX IF NOT EXISTS manifest_receipts_branch_id_idx
  ON public.manifest_receipts (branch_id);
CREATE INDEX IF NOT EXISTS manifest_receipts_received_by_idx
  ON public.manifest_receipts (received_by);
