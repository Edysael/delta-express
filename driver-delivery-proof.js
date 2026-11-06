/* Delta-Express · comprobante digital de entrega */
(function(){
 'use strict';
 const api=()=>window.deltaExpressSupabase;
 const company=()=>api()?.getCompany?.();
 const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 let proofCanvas=null,proofDrawing=false,proofHasInk=false;
 function clearSignature(){if(!proofCanvas)return;const c=proofCanvas.getContext('2d');c.clearRect(0,0,proofCanvas.width,proofCanvas.height);proofHasInk=false;}
 function setupSignature(canvas){
  proofCanvas=canvas;const ctx=canvas.getContext('2d');ctx.lineWidth=3;ctx.lineCap='round';ctx.lineJoin='round';ctx.strokeStyle='#172033';
  const point=e=>{const r=canvas.getBoundingClientRect();return{x:(e.clientX-r.left)*canvas.width/r.width,y:(e.clientY-r.top)*canvas.height/r.height}};
  canvas.onpointerdown=e=>{e.preventDefault();proofDrawing=true;canvas.setPointerCapture(e.pointerId);const p=point(e);ctx.beginPath();ctx.moveTo(p.x,p.y);ctx.lineTo(p.x+.1,p.y+.1);ctx.stroke();proofHasInk=true;};
  canvas.onpointermove=e=>{if(!proofDrawing)return;const p=point(e);ctx.lineTo(p.x,p.y);ctx.stroke();};
  const end=()=>{proofDrawing=false};canvas.onpointerup=end;canvas.onpointercancel=end;canvas.onpointerleave=end;
 }
 function getShipments(){return (window.driverMobileShipments?.()||[]).filter(s=>s.id&&s.status!=='Entregada');}
 function renderProofPanel(){
  if(!getShipments().length)return;
  const host=document.getElementById('driverMobileRoute');if(!host||document.getElementById('dxProofPanel'))return;
  const list=getShipments();const panel=document.createElement('section');panel.id='dxProofPanel';panel.style.cssText='padding:14px;margin:12px 0;border:1px solid #cbd5e1;border-radius:14px;background:var(--card,#fff)';
  panel.innerHTML='<h3 style="margin:0 0 6px">Comprobante digital de entrega</h3><p style="font-size:13px;opacity:.75;margin:0 0 12px">Registra al receptor, fotografía y firma para dejar constancia de la entrega.</p><button type="button" class="btn primary" id="dxProofOpen">Registrar entrega y evidencia</button>';
  host.parentNode?.insertBefore(panel,host);
  panel.querySelector('#dxProofOpen').onclick=()=>openProofForm();
 }
 function openProofForm(){
  const a=api(),c=company();if(!a||!c){window.toast?.('No hay una empresa activa.');return;}
  const list=getShipments();if(!list.length){window.toast?.('No tienes encomiendas pendientes de entrega asignadas.');return;}
  document.getElementById('dxProofModal')?.remove();
  const modal=document.createElement('div');modal.id='dxProofModal';modal.style.cssText='position:fixed;inset:0;z-index:99999;background:#0f172acc;display:flex;align-items:center;justify-content:center;padding:12px;overflow:auto';
  modal.innerHTML='<div style="background:var(--card,#fff);color:var(--text,inherit);width:min(620px,100%);max-height:94vh;overflow:auto;border-radius:16px;padding:18px"><div style="display:flex;justify-content:space-between;align-items:center;gap:10px"><h3 style="margin:0">Confirmar entrega</h3><button type="button" class="btn small" id="dxProofClose">Cerrar</button></div><div class="field" style="margin-top:12px"><label>Encomienda</label><select id="dxProofShipment" style="width:100%">'+list.map(s=>'<option value="'+esc(s.id)+'">'+esc(s.code||s.tracking_code||s.id)+' · '+esc(s.recipient||s.recipient_name||'Destinatario')+'</option>').join('')+'</select></div><div class="field"><label>Nombre de quien recibe *</label><input id="dxProofRecipient" required maxlength="120" autocomplete="name" style="width:100%" placeholder="Nombre y apellido"></div><div class="field"><label>Documento de identidad (opcional)</label><input id="dxProofDocument" maxlength="40" style="width:100%" placeholder="RUT / documento"></div><div class="field"><label>Fotografía de respaldo *</label><input id="dxProofPhoto" type="file" accept="image/jpeg,image/png,image/webp" capture="environment" style="width:100%"></div><div class="field"><label>Firma del receptor *</label><canvas id="dxProofSignature" width="900" height="260" style="width:100%;height:150px;border:1px dashed #94a3b8;border-radius:10px;touch-action:none;background:#fff"></canvas><button type="button" class="btn small" id="dxProofClear" style="margin-top:6px">Borrar firma</button></div><p style="font-size:12px;opacity:.75">Se guardarán fecha, hora y coordenadas del dispositivo. La ubicación requiere autorización GPS.</p><button type="button" class="btn primary" id="dxProofSave" style="width:100%">Guardar comprobante y finalizar entrega</button><p id="dxProofStatus" role="status" style="font-size:13px"></p></div>';
  document.body.appendChild(modal);setupSignature(modal.querySelector('#dxProofSignature'));
  modal.querySelector('#dxProofClose').onclick=()=>modal.remove();modal.querySelector('#dxProofClear').onclick=clearSignature;
  modal.querySelector('#dxProofSave').onclick=async()=>{
   const btn=modal.querySelector('#dxProofSave'),status=modal.querySelector('#dxProofStatus'),shipment=list.find(s=>s.id===modal.querySelector('#dxProofShipment').value);
   const recipient=modal.querySelector('#dxProofRecipient').value.trim(),doc=modal.querySelector('#dxProofDocument').value.trim(),photo=modal.querySelector('#dxProofPhoto').files?.[0];
   if(!shipment||!recipient||!photo||!proofHasInk){status.textContent='Completa el receptor, la fotografía y la firma.';return;}
   if(!['image/jpeg','image/png','image/webp'].includes(photo.type)||photo.size>12*1024*1024){status.textContent='La fotografía debe ser JPG, PNG o WEBP y no superar 12 MB.';return;}
   btn.disabled=true;btn.textContent='Guardando evidencia…';status.textContent='Obteniendo ubicación y preparando archivos…';
   const uploaded=[];
   try{
    const {data:userData,error:userErr}=await a.client.auth.getUser();if(userErr)throw userErr;const user=userData?.user;if(!user)throw new Error('La sesión expiró.');
    const {data:driver,error:driverErr}=await a.client.from('drivers').select('id').eq('company_id',c.id).eq('user_id',user.id).single();if(driverErr)throw driverErr;
    let deliveryId=shipment.deliveryId,delivery=null;
    if(deliveryId){const q=await a.client.from('deliveries').select('id,branch_id,status').eq('id',deliveryId).eq('company_id',c.id).eq('driver_id',driver.id).maybeSingle();if(q.error)throw q.error;delivery=q.data;}
    if(!delivery){const q=await a.client.from('deliveries').select('id,branch_id,status').eq('company_id',c.id).eq('shipment_id',shipment.id).eq('driver_id',driver.id).in('status',['assigned','in_progress']).order('created_at',{ascending:false}).limit(1).maybeSingle();if(q.error)throw q.error;delivery=q.data;deliveryId=delivery?.id;}
    if(!deliveryId||!delivery)throw new Error('No existe una entrega activa asignada para esta encomienda.');
    if(!delivery.branch_id)throw new Error('La entrega no tiene sucursal asociada. Solicita al administrador completar la asignación.');
    let coords=null;try{coords=await new Promise((resolve,reject)=>navigator.geolocation.getCurrentPosition(p=>resolve({latitude:p.coords.latitude,longitude:p.coords.longitude,accuracy_m:p.coords.accuracy}),reject,{enableHighAccuracy:true,timeout:12000,maximumAge:60000}));}catch(e){throw new Error('No se pudo obtener GPS. Activa la ubicación para emitir el comprobante: '+e.message);}
    const signatureBlob=await new Promise((resolve,reject)=>proofCanvas.toBlob(b=>b?resolve(b):reject(new Error('No se pudo generar la firma.')),'image/png'));
    const stamp=Date.now(),base=c.id+'/'+delivery.branch_id+'/'+deliveryId+'/'+stamp;
    const files=[{type:'photo',blob:photo,name:'photo.'+(photo.type==='image/png'?'png':photo.type==='image/webp'?'webp':'jpg'),mime:photo.type,description:'Fotografía de entrega'},{type:'signature',blob:signatureBlob,name:'signature.png',mime:'image/png',description:'Firma del receptor'}];
    for(const f of files){
     const path=base+'/'+f.name;const up=await a.client.storage.from('delta-express-evidence').upload(path,f.blob,{contentType:f.mime,upsert:false});if(up.error)throw up.error;uploaded.push(path);
     const meta={recipient_name:recipient,recipient_document:doc||null,latitude:coords.latitude,longitude:coords.longitude,accuracy_m:coords.accuracy_m,source:'driver_mobile',file_name:f.name,mime_type:f.mime};
     const ins=await a.client.from('delivery_evidence').insert({company_id:c.id,delivery_id:deliveryId,evidence_type:f.type,storage_path:path,description:f.description,captured_by:user.id,metadata:meta});
     if(ins.error)throw ins.error;
    }
    const now=new Date().toISOString();
    const upd=await a.client.from('deliveries').update({status:'delivered',recipient_name:recipient,recipient_document:doc||null,delivered_at:now,latitude:coords.latitude,longitude:coords.longitude,notes:'Entrega confirmada con fotografía, firma y geolocalización.'}).eq('id',deliveryId).eq('company_id',c.id).eq('driver_id',driver.id).select('id').maybeSingle();
    if(upd.error)throw upd.error;if(!upd.data)throw new Error('La evidencia se guardó, pero no se pudo finalizar la entrega por permisos. Contacta al administrador; no repitas el comprobante.');
    const ship=await a.client.from('shipments').update({status:'delivered',delivered_at:now}).eq('id',shipment.id).eq('company_id',c.id);if(ship.error)console.warn('Estado de encomienda pendiente de sincronización:',ship.error);
    const ev=await a.client.from('shipment_events').insert({company_id:c.id,shipment_id:shipment.id,event_type:'delivered',previous_status:'out_for_delivery',new_status:'delivered',description:'Entrega confirmada por '+recipient+' con fotografía, firma y geolocalización.',branch_id:delivery.branch_id,created_by:user.id,event_data:{source:'driver_mobile',delivery_id:deliveryId,recipient_name:recipient,recipient_document:doc||null,latitude:coords.latitude,longitude:coords.longitude,evidence_paths:uploaded}});
    if(ev.error)console.warn('Evento de seguimiento no guardado:',ev.error);
    shipment.status='Entregada';shipment.deliveryStatus='delivered';modal.remove();window.toast?.('Entrega confirmada. Comprobante digital guardado.');await window.refreshDriverMobile?.(false);window.renderDriverApp?.();
   }catch(e){status.textContent='No se pudo completar: '+(e.message||'Error inesperado');btn.disabled=false;btn.textContent='Reintentar guardado';console.error('Delta-Express POD:',e);}
  };
 }
 const prev=window.renderDriverApp;window.renderDriverApp=function(){if(typeof prev==='function')prev();renderProofPanel();};
 document.addEventListener('DOMContentLoaded',()=>renderProofPanel());
})();