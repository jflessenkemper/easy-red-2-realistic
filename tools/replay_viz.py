#!/usr/bin/env python3
"""Self-contained interactive replay of one or more state-log runs (JSONL from tools/slog.py).

One offline HTML file. plotly.js is inlined (no CDN at view time). Views:
  Replay 3D     positions at time t, time scrubber + play, colour by team or by state, decision
                labels, event markers (last 3 s), optional 5 s trails
  Timelines     per soldier: health, suppression value, crawl (prone proxy), reloading (the
                only ammo-related read; ammo itself is not readable), plus a decision/state
                timeline for the selected soldier and for every soldier
  Heatmap       deaths / went_prone / suppressed locations accumulated ACROSS all given runs

The first run is the one replayed; every run feeds the heatmap. A SYNTHETIC banner is shown if any
input header says synthetic (fixtures are hand-scripted and prove the viewer, not the mod).

plotly.js lookup: $PLOTLY_JS, else ~/.local/share/er2-review/plotly-2.35.2.min.js
(fetch once: curl -fsSLo ~/.local/share/er2-review/plotly-2.35.2.min.js https://cdn.plot.ly/plotly-2.35.2.min.js)

Usage: replay_viz.py RUN.jsonl [MORE.jsonl ...] -o out.html [--title T]
"""
import json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import slog as SL

PLOTLY = os.environ.get("PLOTLY_JS") or os.path.expanduser("~/.local/share/er2-review/plotly-2.35.2.min.js")
FIELDS = ("t", "x", "y", "z", "hp", "supv", "sup", "crawl", "rld", "down", "dec", "cover", "veh", "carry")

def pack(path):
    hdr, recs = SL.load(path)
    ents = {}
    for r in recs:
        if r["k"] != "s": continue
        e = ents.setdefault(str(r["id"]), {"tm": r.get("tm", "?"), "role": r.get("role"), **{f: [] for f in FIELDS}})
        for f in FIELDS:
            v = r.get(f)
            if isinstance(v, bool): v = int(v)
            e[f].append(v)
    evs = [{k: r.get(k) for k in ("t", "id", "ev", "x", "y", "z", "to", "from", "tm")} for r in recs if r["k"] == "e"]
    return {"hdr": hdr, "name": os.path.basename(path), "ents": ents, "events": evs}

HTML = r"""<!doctype html><html><head><meta charset="utf-8"><title>__TITLE__</title>
<style>
body{margin:0;font:14px system-ui,sans-serif;background:#0f1218;color:#e6e9ef}
header{padding:10px 16px;background:#181c25;display:flex;gap:16px;align-items:center;flex-wrap:wrap}
.banner{background:#7a2d00;color:#fff;padding:8px 16px;font-weight:600}
button,select,label{font:inherit;color:#e6e9ef;background:#262b38;border:1px solid #3a4152;border-radius:8px;padding:4px 10px}
button.on{background:#3d5afe}.tab{display:none;padding:8px}.tab.on{display:block}
#scrub{width:420px}.meta{opacity:.7;font-size:12px}
</style></head><body>
__BANNER__
<header><b>__TITLE__</b>
<button data-tab="r" class="on">Replay 3D</button><button data-tab="tl">Timelines</button><button data-tab="hm">Heatmap</button>
<span class="meta" id="meta"></span></header>
<div class="tab on" id="tab-r">
 <div style="display:flex;gap:10px;align-items:center;flex-wrap:wrap;padding:6px 8px">
  <button id="play">&#9654; play</button><input type="range" id="scrub" min="0" max="1000" value="0"><span id="tlabel"></span>
  <label>colour <select id="cmode"><option value="team">team</option><option value="state">state</option></select></label>
  <label><input type="checkbox" id="labels" checked> action labels</label>
  <label><input type="checkbox" id="trails"> 5 s trails</label>
 </div><div id="p3d" style="height:72vh"></div></div>
<div class="tab" id="tab-tl">
 <div style="padding:6px 8px"><label>soldier <select id="who"></select></label>
 <span class="meta">ammo is NOT readable from the ER2 Lua API; "reloading" is the only ammo-related signal</span></div>
 <div id="ptl" style="height:42vh"></div><div id="pdec" style="height:18vh"></div><div id="pall" style="height:40vh"></div></div>
<div class="tab" id="tab-hm">
 <div style="padding:6px 8px"><label>layer <select id="hml"><option>died</option><option>went_prone</option><option>suppressed</option></select></label>
 <label>bin m <select id="hmb"><option>5</option><option selected>10</option><option>20</option></select></label>
 <span class="meta" id="hmmeta"></span></div><div id="phm" style="height:75vh"></div></div>
<script>__PLOTLY__</script>
<script>
const RUNS=__DATA__;const R=RUNS[0];const E=R.ents,IDS=Object.keys(E);
const TEAM={I:'#ff6b4a',D:'#4aa3ff','?':'#aaa'};
const STATE=[['down','#888'],['suppressed','#ffd400'],['pinned/cover','#b56bff'],['mounted','#00d0a0'],['moving','#7cff6b'],['idle','#e6e9ef']];
const L={paper_bgcolor:'#0f1218',plot_bgcolor:'#0f1218',font:{color:'#e6e9ef'},margin:{l:50,r:10,t:30,b:40}};
let T0=1e9,T1=-1e9;const BB={x:[1e9,-1e9],z:[1e9,-1e9],y:[1e9,-1e9]};IDS.forEach(i=>['x','z','y'].forEach(a=>E[i][a].forEach(v=>{v=v||0;BB[a][0]=Math.min(BB[a][0],v);BB[a][1]=Math.max(BB[a][1],v);})));
const pad=(r,m)=>[r[0]-m,r[1]+m];const SPAN=Math.max(BB.x[1]-BB.x[0],BB.z[1]-BB.z[0],1);
IDS.forEach(i=>{const t=E[i].t;if(t.length){T0=Math.min(T0,t[0]);T1=Math.max(T1,t[t.length-1]);}});
document.getElementById('meta').textContent=`replaying ${R.name} · mission ${R.hdr.mission} · seed ${R.hdr.seed} · mod ${R.hdr.mod_sha} · ${IDS.length} entities · ${RUNS.length} run(s) in heatmap`;
function idxAt(a,t){let lo=0,hi=a.length-1;if(hi<0||a[0]>t)return -1;while(lo<hi){const m=(lo+hi+1)>>1;if(a[m]<=t)lo=m;else hi=m-1;}return lo;}
function stateOf(e,k){if(e.down[k])return 0;if(e.sup[k])return 1;if(e.cover[k]||/PINNED|cover/.test(e.dec[k]||''))return 2;if(e.veh[k])return 3;
  const k0=Math.max(0,k-1);const d=Math.hypot(e.x[k]-e.x[k0],e.z[k]-e.z[k0]);return d>0.05?4:5;}
function frame(t){const cm=document.getElementById('cmode').value,lab=document.getElementById('labels').checked,tr=document.getElementById('trails').checked;
 const x=[],y=[],z=[],c=[],tx=[],hv=[];const traces=[];
 IDS.forEach(i=>{const e=E[i],k=idxAt(e.t,t);if(k<0||t-e.t[k]>1.0)return;x.push(e.x[k]);y.push(e.z[k]);z.push(e.y[k]||0);
  const s=stateOf(e,k);c.push(cm==='team'?TEAM[e.tm]:STATE[s][1]);tx.push(lab?(e.dec[k]||''):'');
  hv.push(`#${i} ${e.tm} ${e.role||''}<br>${e.dec[k]||''}<br>hp ${e.hp[k]} supv ${e.supv[k]} ${STATE[s][0]}`);
  if(tr){const k0=idxAt(e.t,t-5);if(k0>=0&&k0<k)traces.push({type:'scatter3d',mode:'lines',x:e.x.slice(k0,k+1),y:e.z.slice(k0,k+1),z:e.y.slice(k0,k+1).map(v=>v||0),line:{color:TEAM[e.tm],width:2},hoverinfo:'skip',showlegend:false});}});
 traces.unshift({type:'scatter3d',mode:lab?'markers+text':'markers',x,y,z,text:tx,hovertext:hv,hoverinfo:'text',textfont:{size:9,color:'#cfd6e6'},marker:{size:5,color:c},name:'entities'});
 const ev=R.events.filter(v=>v.t<=t&&v.t>t-3&&v.ev!=='decision');
 traces.push({type:'scatter3d',mode:'markers+text',x:ev.map(v=>v.x),y:ev.map(v=>v.z),z:ev.map(v=>(v.y||0)+3),text:ev.map(v=>v.ev),textfont:{size:10,color:'#ffd400'},marker:{size:7,symbol:'diamond',color:'#ffd400'},name:'events (3 s)'});
 return traces;}
const legend=cm=>cm;
function draw3d(){const t=T0+(T1-T0)*(+document.getElementById('scrub').value/1000);document.getElementById('tlabel').textContent='t = '+t.toFixed(2)+' s';
 const st=document.getElementById('cmode').value==='state'?' · state: '+STATE.map(s=>s[0]).join(' / '):' · team: invader red, defender blue';
 Plotly.react('p3d',frame(t),Object.assign({},L,{title:{text:'positions'+st,font:{size:12}},uirevision:'keep',scene:{xaxis:{title:'x (m)',range:pad(BB.x,10)},yaxis:{title:'z (m)',range:pad(BB.z,10)},zaxis:{title:'height (m)',range:pad(BB.y,8)},aspectmode:'manual',aspectratio:{x:(BB.x[1]-BB.x[0]+20)/SPAN,y:(BB.z[1]-BB.z[0]+20)/SPAN,z:0.25},camera:{eye:{x:0.55,y:-0.85,z:0.45}},bgcolor:'#0f1218'}}));
 markTime(t);}
let playing=null;document.getElementById('play').onclick=()=>{if(playing){clearInterval(playing);playing=null;return;}
 playing=setInterval(()=>{const s=document.getElementById('scrub');s.value=(+s.value+4)%1001;draw3d();},100);};
['scrub','cmode','labels','trails'].forEach(id=>document.getElementById(id).oninput=draw3d);
const who=document.getElementById('who');IDS.forEach(i=>{const o=document.createElement('option');o.value=i;o.textContent=`#${i} ${E[i].tm} ${E[i].role||''}`;who.appendChild(o);});
function segs(e){const out=[];let s=0;for(let k=1;k<=e.t.length;k++){if(k===e.t.length||e.dec[k]!==e.dec[s]){out.push([e.t[s],e.t[k-1],e.dec[s]]);s=k;}}return out;}
const DECC={};let dn=0;const PAL=['#ff6b4a','#4aa3ff','#7cff6b','#ffd400','#b56bff','#00d0a0','#ff4fa3','#ffa64a','#9aa4b8','#57e0ff'];
function dcol(d){if(!(d in DECC))DECC[d]=PAL[dn++%PAL.length];return DECC[d];}
function barsFor(list){const bys={};list.forEach(([row,a,b,d])=>{(bys[d]=bys[d]||{x:[],y:[],base:[]});bys[d].x.push(Math.max(b-a,0.25));bys[d].y.push(row);bys[d].base.push(a);});
 return Object.keys(bys).map(d=>({type:'bar',orientation:'h',name:d,x:bys[d].x,y:bys[d].y,base:bys[d].base,marker:{color:dcol(d)},hovertemplate:d+' %{base:.1f}s +%{x:.1f}s<extra></extra>'}));}
function drawTL(){const e=E[who.value];
 Plotly.react('ptl',[{x:e.t,y:e.hp,name:'health',line:{color:'#7cff6b'}},{x:e.t,y:e.supv,name:'suppression value',line:{color:'#ffd400'}},
  {x:e.t,y:e.crawl.map(v=>v*100),name:'crawl (prone proxy) x100',line:{color:'#b56bff',shape:'hv'}},{x:e.t,y:e.rld.map(v=>v*50),name:'reloading x50 (ammo n/a)',line:{color:'#4aa3ff',shape:'hv'}},
  {x:e.t,y:e.sup.map(v=>v*90),name:'isSuppressed x90',line:{color:'#ff6b4a',shape:'hv',dash:'dot'}}],
  Object.assign({},L,{title:{text:'soldier #'+who.value+' state over time',font:{size:12}},xaxis:{title:'t (s)'},shapes:[]}));
 Plotly.react('pdec',barsFor(segs(e).map(s=>['#'+who.value,...s])),Object.assign({},L,{barmode:'overlay',title:{text:'decision timeline (selected)',font:{size:12}},xaxis:{title:'t (s)'},showlegend:true}));
 markTime(T0+(T1-T0)*(+document.getElementById('scrub').value/1000));}
function drawAll(){const list=[];IDS.forEach(i=>segs(E[i]).forEach(s=>list.push(['#'+i+' '+E[i].tm,...s])));
 Plotly.react('pall',barsFor(list),Object.assign({},L,{barmode:'overlay',title:{text:'decision/state timeline, every soldier',font:{size:12}},xaxis:{title:'t (s)'},yaxis:{automargin:true}}));}
function markTime(t){['ptl','pdec','pall'].forEach(id=>{const d=document.getElementById(id);if(d.data)Plotly.relayout(d,{shapes:[{type:'line',xref:'x',yref:'paper',x0:t,x1:t,y0:0,y1:1,line:{color:'#fff',width:1,dash:'dot'}}]});});}
who.onchange=drawTL;
function drawHM(){const ev=document.getElementById('hml').value,b=+document.getElementById('hmb').value;const x=[],y=[];let n=0;
 RUNS.forEach(r=>r.events.forEach(v=>{if(v.ev===ev){x.push(v.x);y.push(v.z);n++;}}));
 document.getElementById('hmmeta').textContent=`${n} "${ev}" events across ${RUNS.length} run(s): ${RUNS.map(r=>r.name+(r.hdr.synthetic?' [SYNTHETIC]':'')).join(', ')}`;
 Plotly.react('phm',[{type:'histogram2d',x,y,xbins:{size:b},ybins:{size:b},colorscale:[[0,'rgba(0,0,0,0)'],[1e-6,'#2c105c'],[0.5,'#d6456c'],[1,'#fcfdbf']],colorbar:{title:'count'}},
  {type:'scatter',mode:'markers',x,y,marker:{size:5,color:'#4aa3ff'},name:'event'}],Object.assign({},L,{title:{text:ev+' locations (top-down, '+b+' m bins)',font:{size:12}},xaxis:{title:'x (m)'},yaxis:{title:'z (m)',scaleanchor:'x'}}));}
['hml','hmb'].forEach(id=>document.getElementById(id).onchange=drawHM);
document.querySelectorAll('header button[data-tab]').forEach(b=>b.onclick=()=>{document.querySelectorAll('header button[data-tab]').forEach(x=>x.classList.toggle('on',x===b));
 document.querySelectorAll('.tab').forEach(x=>x.classList.toggle('on',x.id==='tab-'+b.dataset.tab));
 if(b.dataset.tab==='tl'){drawTL();drawAll();}if(b.dataset.tab==='hm')drawHM();window.dispatchEvent(new Event('resize'));});
draw3d();
const h=new URLSearchParams(location.hash.slice(1));if(h.get('t'))document.getElementById('scrub').value=h.get('t'),draw3d();
if(h.get('tab'))document.querySelector('header button[data-tab="'+h.get('tab')+'"]').click();
</script></body></html>"""

def build(paths, out, title=None):
    if not os.path.exists(PLOTLY):
        sys.exit("plotly.js not found at %s (see --help for the one-time fetch)" % PLOTLY)
    runs = [pack(p) for p in paths]
    syn = any(r["hdr"].get("synthetic") for r in runs)
    title = title or ("Replay: " + runs[0]["name"])
    banner = ('<div class="banner">SYNTHETIC FIXTURE: hand-scripted data that proves the viewer works. '
              'It is NOT game output and NOT evidence for any feature.</div>') if syn else ""
    html = (HTML.replace("__PLOTLY__", open(PLOTLY, encoding="utf-8").read().replace("</script", "<\\/script"))
            .replace("__DATA__", json.dumps(runs, separators=(",", ":")).replace("</", "<\\/"))
            .replace("__TITLE__", title.replace("<", "&lt;")).replace("__BANNER__", banner))
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    open(out, "w", encoding="utf-8").write(html)
    return {"out": out, "runs": len(runs), "synthetic": syn, "entities": len(runs[0]["ents"]),
            "events": len(runs[0]["events"]), "bytes": len(html)}

def main(argv):
    if not argv or argv[0] in ("-h", "--help") or "-o" not in argv: print(__doc__); return 0 if argv and argv[0] in ("-h", "--help") else 2
    o = argv[argv.index("-o") + 1]
    title = argv[argv.index("--title") + 1] if "--title" in argv else None
    skip = {o, title}
    paths = [a for i, a in enumerate(argv) if not a.startswith("-") and a not in skip]
    r = build(paths, o, title)
    print("replay: %(out)s  (%(runs)d run(s), %(entities)d entities, %(events)d events, %(bytes)d bytes, synthetic=%(synthetic)s)" % r)
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
