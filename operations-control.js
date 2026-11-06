/* Delta-Express · centro de control operativo */
(function(){
 'use strict';
 const api=()=>window.deltaExpressSupabase;
 const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 const fmt=v=>v?new Date(v).toLocaleString('es-CL'):'—';
 const age=v=>{if(!v)return '—';const h=Math.max(0,Math.floor((Date.now()-new Date(v).getTime())/3600000));return h<1?'menos de 1 h':h<24?h+' h':Math.floor(h/24)+' d';};
 let busy=false,lastRows=[];
 function host(){let d=document.getElementById('dashboard');if(!d)return null;let p=document.getElementById('dxOperationsCenter');if(!p){p=document.createElement('section');p.id='dxOperationsCenter';p.className='card';p.style.cssText='margin:18px 0;padding:16px;border:1px solid var(--line,#203b68);';d.appendChild(p);}return p;}
 function statusLabel(s){return ({assigned:'Asignada',in_progress:'En reparto',delivered:'Entregada',failed:'Fallida',rescheduled:'Reprogramada',returned:'Devuelta'})[s]||s||'—';}
 function renderShell(p){p.innerHTML=`
  <div class="cardtitle" style="display:flex;align-items:center;justify-content:space-between;gap:12px;flex-wrap:wrap"><div><div class="eyebrow">LOGÍSTICA · SUPABASE</div><h3 style="margin:4px 0">Centro de control operativo</h3><p class="muted" style="margin:0">Estado real de entregas, alertas por falta de movimiento y trazabilidad.</p></div><button class="btn small" id="dxOpsRefresh">↻ Actualizar datos</button></div>
  <div id="dxOpsNotice" class="notice" style="margin:12px 0">Consultando operaciones de la empresa…</div>
  <div id="dxOpsKpis" class="grid stats" style="grid-template-columns:repeat(auto-fit,minmax(130px,1fr));gap:10px"></div>
  <div class="grid cols" style="margin-top:14px;gap:14px">
   <div class="tile"><h4 style="margin-top:0">Buscar seguimiento</h4><div style="display:flex;gap:8px;flex-wrap:wrap"><input id="dxOpsTrack" placeholder="Código de seguimiento" style="flex:1;min-width:180px"><button class="btn primary small" id="dxOpsTrackBtn">Consultar</button></div><div id="dxOpsTrackResult" style="margin-top:10px"></div></div>
   <div class="tile"><h4 style="margin-top:0">Alertas operativas</h4><div id="dxOpsAlerts" class="muted">Calculando alertas…</div></div>
  </div>
  <div style="margin-top:16px"><div class="cardtitle"><h4>Entregas recientes</h4><span class="muted" id="dxOpsCount"></span></div><div class="tablewrap"><table class="table" id="dxOpsTable"><thead><tr><th>Seguimiento</th><th>Estado</th><th>Conductor</th><th>Sucursal</th><th>Último cambio</th><th>Antigüedad</th><th>Evidencia</th><th>Acciones</th></tr></thead><tbody><tr><td colspan="8">Cargando…</td></tr></tbody></table></div></div>
  <div class="grid cols" style="margin-top:16px;gap:14px"><div class="tile"><h4 style="margin-top:0">Entregas por conductor</h4><div id="dxOpsDrivers" class="muted">—</div></div><div class="tile"><h4 style="margin-top:0">Entregas por sucursal</h4><div id="dxOpsBranches" class="muted">—</div></div></div>`;
  p.querySelector('#dxOpsRefresh').onclick=()=>load(true);
  p.querySelector('#dxOpsTrackBtn').onclick=()=>track(p.querySelector('#dxOpsTrack').value.trim());
  p.querySelector('#dxOpsTrack').addEventListener('keydown',e=>{if(e.key==='Enter')track(e.currentTarget.value.trim());});
  p.querySelector('#dxOpsTable').addEventListener('click',e=>{const b=e.target.closest('[data-evidence]');if(b){showEvidence(b.dataset.evidence);return;}const r=e.target.closest('[data-retry]');if(r){if(typeof window.scheduleDeliveryRetry==='function')window.scheduleDeliveryRetry(r.dataset.retry);else alert('La función de reprogramación no está disponible.');return;}const rt=e.target.closest('[data-return]');if(rt){if(typeof window.confirmReturnToBranch==='function')window.confirmReturnToBranch(rt.dataset.return);else alert('La función de retorno no está disponible.');return;}});
 }
 async function load(force){
  if(busy)return;const p=host();if(!p)return;if(!p.querySelector('#dxOpsRefresh'))renderShell(p);
  const a=api(),c=a?.getCompany?.();if(!a||!c){p.querySelector('#dxOpsNotice').textContent='Inicia sesión y selecciona una empresa para consultar operaciones.';return;}
  busy=true;const notice=p.querySelector('#dxOpsNotice');notice.textContent='Sincronizando entregas y trazabilidad…';
  try{
   const {data:deliveries,error}=await a.client.from('deliveries').select('id,company_id,shipment_id,driver_id,branch_id,status,attempt_number,recipient_name,delivered_at,updated_at,created_at,next_attempt_at').eq('company_id',c.id).order('updated_at',{ascending:false}).limit(500);
   if(error)throw error;
   const rows=deliveries||[],shipmentIds=[...new Set(rows.map(x=>x.shipment_id).filter(Boolean))],driverIds=[...new Set(rows.map(x=>x.driver_id).filter(Boolean))],branchIds=[...new Set(rows.map(x=>x.branch_id).filter(Boolean))];
   const [ships,drivers,branches]=await Promise.all([
    shipmentIds.length?a.client.from('shipments').select('id,tracking_code,recipient_name,destination_city,status').eq('company_id',c.id).in('id',shipmentIds):Promise.resolve({data:[],error:null}),
    driverIds.length?a.client.from('drivers').select('id,full_name').eq('company_id',c.id).in('id',driverIds):Promise.resolve({data:[],error:null}),
    branchIds.length?a.client.from('branches').select('id,name,city').eq('company_id',c.id).in('id',branchIds):Promise.resolve({data:[],error:null})
   ]);
   if(ships.error)throw ships.error;if(drivers.error)throw drivers.error;if(branches.error)throw branches.error;
   const sm=new Map((ships.data||[]).map(x=>[x.id,x])),dm=new Map((drivers.data||[]).map(x=>[x.id,x])),bm=new Map((branches.data||[]).map(x=>[x.id,x]));
   lastRows=rows.map(r=>({...r,shipment:sm.get(r.shipment_id)||{},driver:dm.get(r.driver_id)||{},branch:bm.get(r.branch_id)||{}}));
   const count=s=>rows.filter(r=>r.status===s).length,active=count('assigned')+count('in_progress'),delivered=count('delivered'),failed=count('failed');
   p.querySelector('#dxOpsKpis').innerHTML=[['Total entregas',rows.length],['En curso',active],['Entregadas',delivered],['Fallidas',failed]].map(([k,v])=>'<div class="card stat"><div class="statlabel">'+k+'</div><div class="statvalue">'+v+'</div></div>').join('');
   const alerts=lastRows.filter(r=>(r.status==='in_progress'&&Date.now()-new Date(r.updated_at).getTime()>2*3600000)||(r.status==='assigned'&&Date.now()-new Date(r.updated_at).getTime()>4*3600000));
   p.querySelector('#dxOpsAlerts').innerHTML=alerts.length?alerts.slice(0,12).map(r=>'<div style="padding:7px 0;border-bottom:1px solid var(--line,#203b68)">⚠ <b>'+esc(r.shipment.tracking_code||r.shipment_id)+'</b> · '+(r.status==='in_progress'?'Sin movimiento registrado hace ':'Asignada sin iniciar hace ')+age(r.updated_at)+'</div>').join(''):'<div class="empty">No hay alertas por antigüedad. Umbrales: 2 h en reparto y 4 h asignada.</div>';
   p.querySelector('#dxOpsTable tbody').innerHTML=lastRows.slice(0,100).map(r=>'<tr><td class="code">'+esc(r.shipment.tracking_code||'—')+'</td><td>'+esc(statusLabel(r.status))+'</td><td>'+esc(r.driver.full_name||'Sin asignar')+'</td><td>'+esc(r.branch.name||r.branch.city||'—')+'</td><td>'+fmt(r.updated_at)+'</td><td>'+age(r.updated_at)+'</td><td><button class="btn small" data-evidence="'+esc(r.id)+'">Ver evidencia</button></td><td>'+(r.status==='failed'||r.status==='rescheduled'?'<button class="btn small" data-retry="'+esc(r.id)+'">Reprogramar</button> ':'')+(r.status==='failed'||r.status==='rescheduled'?'<button class="btn small" data-return="'+esc(r.id)+'">Retorno a sucursal</button>':'—')+'</td></tr>').join('')||'<tr><td colspan="7" class="empty">No hay entregas registradas.</td></tr>';
   p.querySelector('#dxOpsCount').textContent=rows.length+' registros · mostrando hasta 100';
   const group=(key,field)=>{const m=new Map();lastRows.forEach(r=>{const n=(field==='driver.full_name'?r.driver.full_name:r.branch.name)||'Sin asignar';if(!m.has(n))m.set(n,{total:0,delivered:0});const v=m.get(n);v.total++;if(r.status==='delivered')v.delivered++;});return [...m.entries()].sort((a,b)=>b[1].total-a[1].total).slice(0,8).map(([n,v])=>'<div style="display:flex;justify-content:space-between;padding:5px 0;border-bottom:1px solid var(--line,#203b68)"><span>'+esc(n)+'</span><b>'+v.delivered+'/'+v.total+'</b></div>').join('')||'Sin datos';};
   p.querySelector('#dxOpsDrivers').innerHTML=group('driver','driver.full_name');p.querySelector('#dxOpsBranches').innerHTML=group('branch','branch.name');
   notice.textContent='Datos actualizados: '+new Date().toLocaleTimeString('es-CL')+'. Los avisos se calculan con la antigüedad de updated_at; no representan una ETA contractual.';
  }catch(e){notice.textContent='No se pudieron consultar las operaciones: '+(e.message||'Error de permisos o conexión')+'. La consulta respeta las políticas RLS de Supabase.';console.error('Delta-Express operaciones:',e);}
  finally{busy=false;}
 }
 async function track(code){
  const p=host(),box=p?.querySelector('#dxOpsTrackResult'),a=api(),c=a?.getCompany?.();if(!box||!a||!c)return;
  if(!code){box.textContent='Introduce un código de seguimiento.';return;}
  box.textContent='Consultando…';
  try{
   const {data:s,error}=await a.client.from('shipments').select('id,tracking_code,status,recipient_name,destination_city,created_at,delivered_at').eq('company_id',c.id).eq('tracking_code',code).maybeSingle();if(error)throw error;if(!s){box.textContent='No se encontró ese código en esta empresa.';return;}
   const {data:events,error:ee}=await a.client.from('shipment_events').select('event_type,previous_status,new_status,description,location_text,created_at').eq('company_id',c.id).eq('shipment_id',s.id).order('created_at',{ascending:false}).limit(20);if(ee)throw ee;
   box.innerHTML='<b>'+esc(s.tracking_code)+'</b> · '+esc(s.status)+'<div class="muted" style="margin:4px 0 8px">Destinatario: '+esc(s.recipient_name)+' · Destino: '+esc(s.destination_city||'—')+'</div>'+((events||[]).map(e=>'<div style="padding:7px 0;border-top:1px solid var(--line,#203b68)"><b>'+esc(e.new_status||e.event_type)+'</b> · '+fmt(e.created_at)+'<div class="muted">'+esc(e.description||e.location_text||'')+'</div></div>').join('')||'<div class="muted">Sin movimientos adicionales.</div>');
  }catch(e){box.textContent='Error al consultar seguimiento: '+(e.message||e);}
 }
 async function showEvidence(deliveryId){
  const p=host(),a=api(),c=a?.getCompany?.();if(!p||!a||!c)return;
  const row=lastRows.find(x=>x.id===deliveryId);if(!row)return;
  const old=document.getElementById('dxEvidenceModal');old?.remove();
  const modal=document.createElement('div');modal.id='dxEvidenceModal';modal.style.cssText='position:fixed;inset:0;z-index:100000;background:#020817d9;display:flex;align-items:center;justify-content:center;padding:12px';
  modal.innerHTML='<div style="width:min(680px,100%);max-height:90vh;overflow:auto;background:var(--panel,#0c1d3b);color:var(--text,#fff);border:1px solid var(--line,#203b68);border-radius:14px;padding:16px"><div style="display:flex;justify-content:space-between;gap:8px"><h3>Historial de evidencias · '+esc(row.shipment.tracking_code||'Entrega')+'</h3><button class="btn small" id="dxEvidenceClose">Cerrar</button></div><div id="dxEvidenceItems">Consultando evidencias…</div></div>';
  document.body.appendChild(modal);modal.querySelector('#dxEvidenceClose').onclick=()=>modal.remove();
  try{
   const {data,error}=await a.client.from('delivery_evidence').select('id,evidence_type,storage_path,description,captured_at,metadata').eq('company_id',c.id).eq('delivery_id',deliveryId).order('captured_at',{ascending:false});if(error)throw error;
   const items=modal.querySelector('#dxEvidenceItems');if(!data?.length){items.textContent='Esta entrega todavía no tiene evidencias registradas.';return;}
   const links=await Promise.all(data.map(async ev=>{if(!ev.storage_path)return {...ev,url:null};const signed=await a.client.storage.from('delta-express-evidence').createSignedUrl(ev.storage_path,300);return {...ev,url:signed.error?null:signed.data?.signedUrl};}));
   items.innerHTML=links.map(ev=>'<div style="padding:10px 0;border-top:1px solid var(--line,#203b68)"><b>'+esc(ev.evidence_type)+'</b> · '+fmt(ev.captured_at)+'<div class="muted">'+esc(ev.description||'')+'</div>'+(ev.url?'<a href="'+esc(ev.url)+'" target="_blank" rel="noopener">Abrir archivo privado ↗</a>':'<span class="muted">Archivo no disponible o sin permiso</span>')+'</div>').join('');
  }catch(e){modal.querySelector('#dxEvidenceItems').textContent='No se pudo consultar la evidencia: '+(e.message||e);}
 }
 function activate(){const d=document.getElementById('dashboard');if(d?.classList.contains('active'))load(false);}
 document.addEventListener('DOMContentLoaded',()=>{activate();const d=document.getElementById('dashboard');if(d)new MutationObserver(activate).observe(d,{attributes:true,attributeFilter:['class']});document.addEventListener('click',e=>{if(e.target.closest('.nav[data-page="dashboard"]'))setTimeout(activate,100);});});
})();
