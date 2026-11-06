/* Delta-Express · módulo móvil operativo del conductor */
(function(){
 'use strict';
 const api=()=>window.deltaExpressSupabase;
 const company=()=>api()?.getCompany?.();
 const isDriver=()=>['driver','transportista'].includes(String(currentUser?.role||'').toLowerCase());
 let liveShipments=[];
 let liveDriver=null;
 const statusLabel={assigned:'Asignada',in_progress:'En reparto',delivered:'Entregada',failed:'Intento fallido',rescheduled:'Reprogramada',returned:'Devuelta'};
 const shipmentStatus={registered:'Registrada',received:'Recibida',sorting:'En clasificación',dispatched:'Despachada',in_transit:'En tránsito',at_destination_branch:'En sucursal destino',out_for_delivery:'En reparto',delivery_failed:'Entrega fallida',delivered:'Entregada',incident:'Incidencia',returned:'Devuelta',on_hold:'Retenida'};
 async function loadAssigned(){
  const a=api(),c=company(); if(!a||!c) return [];
  const {data:u,error:ue}=await a.client.auth.getUser(); if(ue) throw ue;
  if(!u?.user) throw new Error('La sesión no está activa.');
  const {data:d,error:de}=await a.client.from('drivers').select('id,full_name,phone,license_number,license_class').eq('company_id',c.id).eq('user_id',u.user.id).maybeSingle();
  if(de) throw de;
  if(!d) throw new Error('Tu usuario todavía no está vinculado a una ficha de conductor. Solicita al administrador que lo vincule desde Transporte.');
  liveDriver=d;
  const [m,dl]=await Promise.all([
   a.client.from('manifests').select('id,manifest_number,status,manifest_shipments(shipments(id,tracking_code))').eq('company_id',c.id).eq('driver_id',d.id).not('status','in','("cancelled","closed")').order('created_at',{ascending:false}).limit(100),
   a.client.from('deliveries').select('id,shipment_id,attempt_number,status,recipient_name,delivered_at,notes,created_at').eq('company_id',c.id).eq('driver_id',d.id).order('created_at',{ascending:false}).limit(200)
  ]);
  if(m.error) throw m.error; if(dl.error) throw dl.error;
  const ids=new Set(),codes=new Set();
  (m.data||[]).forEach(x=>(x.manifest_shipments||[]).forEach(z=>{if(z.shipments?.id)ids.add(z.shipments.id);if(z.shipments?.tracking_code)codes.add(z.shipments.tracking_code)}));
  (dl.data||[]).forEach(x=>ids.add(x.shipment_id));
  liveShipments=(db?.shipments||[]).filter(s=>ids.has(s.id)||codes.has(s.code));
  liveShipments.forEach(s=>{
   const records=(dl.data||[]).filter(x=>x.shipment_id===s.id);
   const latest=records[0];
   if(latest){
    s.deliveryId=latest.id;s.deliveryStatus=latest.status;
    if(latest.status==='delivered')s.status='Entregada';
    else if(latest.status==='in_progress')s.status='En reparto';
    else if(latest.status==='failed')s.status='Entrega fallida';
    else if(latest.status==='returned')s.status='Devuelta';
    if(latest.recipient_name)s.deliveryRecipient=latest.recipient_name;
   }
  });
  return liveShipments.filter(s=>!['Devuelta','Extraviada'].includes(s.status));
 }
 window.refreshDriverMobile=async function(showToast=true){
  try{await loadAssigned();if(typeof renderDriverApp==='function')renderDriverApp();if(showToast)window.toast?.('Asignaciones actualizadas desde Supabase.');}
  catch(e){if(showToast)window.toast?.('No se pudieron cargar tus asignaciones: '+(e.message||'Error'));console.error('Delta-Express driver refresh:',e);}
 };
 const oldShipments=window.driverMobileShipments;
 window.driverMobileShipments=function(){
  if(isDriver()) return liveShipments.filter(s=>!['Devuelta','Extraviada'].includes(s.status));
  return typeof oldShipments==='function'?oldShipments():[];
 };
 const oldRender=window.renderDriverApp;
 window.renderDriverApp=function(){
  if(typeof oldRender==='function')oldRender();
  if(!isDriver())return;
  const host=document.getElementById('driverMobileRoute');
  if(host&&!document.getElementById('dxDriverRefresh')){
   const b=document.createElement('button');b.id='dxDriverRefresh';b.className='btn small';b.textContent='↻ Actualizar asignaciones';b.style.margin='0 0 10px';
   b.onclick=()=>window.refreshDriverMobile(true);host.parentNode?.insertBefore(b,host);
  }
  if(!liveDriver) window.refreshDriverMobile(false);
 };
 window.driverMobileUpdate=async function(code,status){
  const a=api(),c=company(),s=(db?.shipments||[]).find(x=>x.code===code);
  if(!a||!c||!s?.id){window.toast?.('No se encontró una encomienda válida en Supabase.');return;}
  if(status!=='En reparto'){window.toast?.('Desde esta acción solo se permite iniciar el reparto. La entrega final requiere registrar su evidencia.');return;}
  try{
   const {data:u,error:ue}=await a.client.auth.getUser();if(ue)throw ue;if(!u?.user)throw new Error('La sesión expiró.');
   const {data:d,error:de}=await a.client.from('drivers').select('id').eq('company_id',c.id).eq('user_id',u.user.id).single();if(de)throw de;
   const allowed=liveShipments.some(x=>x.id===s.id);if(!allowed)throw new Error('Esta encomienda no está asignada a tu usuario.');
   const {data:active,error:ae}=await a.client.from('deliveries').select('id,status,attempt_number').eq('company_id',c.id).eq('shipment_id',s.id).eq('driver_id',d.id).in('status',['assigned','in_progress']).order('created_at',{ascending:false}).limit(1).maybeSingle();if(ae)throw ae;
   let deliveryId=active?.id;
   if(active){
    const {data:updated,error}=await a.client.from('deliveries').update({status:'in_progress',notes:'Reparto iniciado desde la app móvil'}).eq('id',active.id).eq('company_id',c.id).select('id').maybeSingle();
    if(error)throw error;if(!updated)throw new Error('No se pudo actualizar la entrega. Verifica los permisos de tu sucursal.');
   }else{
    const {data:created,error}=await a.client.from('deliveries').insert({company_id:c.id,shipment_id:s.id,driver_id:d.id,branch_id:s.destinationBranchId||null,attempt_number:1,status:'in_progress',notes:'Reparto iniciado desde la app móvil'}).select('id').single();
    if(error)throw error;deliveryId=created.id;
   }
   const {error:se}=await a.client.from('shipments').update({status:'out_for_delivery'}).eq('id',s.id).eq('company_id',c.id);if(se)throw se;
   const {error:ev}=await a.client.from('shipment_events').insert({company_id:c.id,shipment_id:s.id,event_type:'out_for_delivery',previous_status:s.status==='En reparto'?'out_for_delivery':'at_destination_branch',new_status:'out_for_delivery',description:'Encomienda incorporada al reparto por el conductor '+(liveDriver?.full_name||''),branch_id:s.destinationBranchId||null,created_by:u.user.id,event_data:{source:'driver_mobile',delivery_id:deliveryId}});
   if(ev)console.warn('No se pudo agregar el evento de seguimiento:',ev.message);
   s.status='En reparto';s.deliveryId=deliveryId;
   await a.refresh();await window.refreshDriverMobile(false);
   window.toast?.('Reparto iniciado y sincronizado con Delta-Express.');
  }catch(e){window.toast?.('No se pudo iniciar el reparto: '+(e.message||'Error de Supabase'));}
 };
 document.addEventListener('DOMContentLoaded',()=>{if(isDriver())window.refreshDriverMobile(false);});

 let gpsWatchId=null,lastGpsSent=0;
 async function saveGpsPosition(pos){
  const a=api(),c=company();if(!a||!c||!liveDriver)return;
  const now=Date.now();if(now-lastGpsSent<45000)return;lastGpsSent=now;
  const p=pos.coords;
  const {data:u,error:ue}=await a.client.auth.getUser();if(ue)throw ue;if(!u?.user)throw new Error('Sesión vencida');
  const {error}=await a.client.from('driver_location_pings').insert({company_id:c.id,driver_id:liveDriver.id,latitude:p.latitude,longitude:p.longitude,accuracy_m:p.accuracy??null,speed_mps:p.speed??null,heading_deg:p.heading??null,captured_at:new Date(pos.timestamp||now).toISOString()});
  if(error)throw error;
  const label=document.getElementById('dxGpsStatus');if(label)label.textContent='GPS activo · precisión '+Math.round(p.accuracy||0)+' m · última señal '+new Date().toLocaleTimeString('es-CL');
 }
 function renderGpsControls(){
  const host=document.getElementById('driverMobileRoute');if(!host||document.getElementById('dxGpsPanel'))return;
  const panel=document.createElement('section');panel.id='dxGpsPanel';panel.style.cssText='padding:12px;margin:0 0 12px;border:1px solid #cbd5e1;border-radius:12px';
  panel.innerHTML='<b>Seguimiento GPS del reparto</b><p id="dxGpsStatus" style="font-size:12px;margin:6px 0 10px">GPS detenido. Actívalo cuando comiences tu jornada de reparto.</p><button id="dxGpsStart" class="btn primary" type="button">Iniciar seguimiento GPS</button> <button id="dxGpsStop" class="btn small" type="button" disabled>Detener</button>';
  host.parentNode?.insertBefore(panel,host);
  panel.querySelector('#dxGpsStart').onclick=async()=>{
   if(!navigator.geolocation){window.toast?.('Este dispositivo no admite geolocalización.');return;}
   try{await loadAssigned();}catch(e){window.toast?.(e.message);return;}if(!liveDriver)return;
   navigator.geolocation.getCurrentPosition(async pos=>{
    try{lastGpsSent=0;await saveGpsPosition(pos);}catch(e){window.toast?.('No se pudo guardar la ubicación: '+e.message);return;}
    if(gpsWatchId!==null)navigator.geolocation.clearWatch(gpsWatchId);
    gpsWatchId=navigator.geolocation.watchPosition(async p=>{try{await saveGpsPosition(p);}catch(e){console.warn('GPS Delta-Express:',e);}},err=>{const el=document.getElementById('dxGpsStatus');if(el)el.textContent='GPS interrumpido: '+err.message;},{enableHighAccuracy:true,maximumAge:15000,timeout:20000});
    panel.querySelector('#dxGpsStart').disabled=true;panel.querySelector('#dxGpsStop').disabled=false;
    window.toast?.('Seguimiento GPS iniciado. Se guardará una posición aproximadamente cada 45 segundos.');
   },err=>window.toast?.('No se pudo obtener la ubicación: '+err.message),{enableHighAccuracy:true,maximumAge:0,timeout:20000});
  };
  panel.querySelector('#dxGpsStop').onclick=()=>{if(gpsWatchId!==null)navigator.geolocation.clearWatch(gpsWatchId);gpsWatchId=null;panel.querySelector('#dxGpsStart').disabled=false;panel.querySelector('#dxGpsStop').disabled=true;const el=document.getElementById('dxGpsStatus');if(el)el.textContent='Seguimiento GPS detenido por el conductor.';};
 }
 const priorRenderGps=window.renderDriverApp;
 window.renderDriverApp=function(){if(typeof priorRenderGps==='function')priorRenderGps();if(isDriver())renderGpsControls();};

})();
