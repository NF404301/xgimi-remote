#!/usr/bin/env python3
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from xgimi_remote import shell, KEYS
HTML='''<!doctype html><html lang="zh"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>极米遥控器</title><style>
body{background:#10141d;color:#eef2ff;font:16px system-ui;margin:0;display:flex;justify-content:center}main{width:min(420px,90vw);padding:36px 0}h1{font-size:28px;margin-bottom:6px}p{color:#a9b4ca}.pad{display:grid;grid-template-columns:repeat(3,1fr);gap:12px;margin:28px 0}.row{display:grid;grid-template-columns:repeat(3,1fr);gap:12px;margin:12px 0}button{border:1px solid #39445b;background:#202a3e;color:white;border-radius:18px;min-height:68px;font-size:17px;cursor:pointer;touch-action:manipulation}button:active{background:#5279d8}button:disabled{opacity:.5}.ok{background:#4265ca}.blank{visibility:hidden}#status{padding:18px;border-radius:14px;background:#1b2333;white-space:pre-wrap;min-height:45px;font-size:14px}small{color:#a9b4ca}</style><main><h1>极米遥控器</h1><p>Wi-Fi · 192.168.1.100</p><div class="pad"><span></span><button data-key="up" aria-label="向上">↑</button><span></span><button data-key="left" aria-label="向左">←</button><button class="ok" data-key="ok">确认</button><button data-key="right" aria-label="向右">→</button><span></span><button data-key="down" aria-label="向下">↓</button><span></span></div><div class="row"><button data-key="back">返回</button><button data-key="home">主页</button><button data-key="menu">菜单</button></div><div class="row"><button data-key="volume-down">音量 −</button><button data-key="mute">静音</button><button data-key="volume-up">音量 +</button></div><div class="row"><button data-key="play-pause">播放 / 暂停</button><button data-key="info">检查连接</button></div><p id="status" role="status">点击“检查连接”测试投影仪。</p><small>也支持键盘方向键、Enter 确认、Escape 返回。</small></main><script>
let busy=false;async function send(key){if(busy)return;busy=true;document.querySelectorAll('button').forEach(b=>b.disabled=true);let status=document.querySelector('#status');status.textContent='正在发送…';try{let r=await fetch('/control',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({key})});let d=await r.json();status.textContent=d.ok?'✓ '+d.message:'连接失败：'+d.message}catch(e){status.textContent='请求失败：'+e.message}finally{busy=false;document.querySelectorAll('button').forEach(b=>b.disabled=false)}}document.querySelectorAll('[data-key]').forEach(b=>b.onclick=()=>send(b.dataset.key));document.addEventListener('keydown',e=>{let k={ArrowUp:'up',ArrowDown:'down',ArrowLeft:'left',ArrowRight:'right',Enter:'ok',Escape:'back'}[e.key];if(k){e.preventDefault();send(k)}});
</script></html>'''
class Handler(BaseHTTPRequestHandler):
 def do_GET(self):
  if self.path!='/':self.send_error(404);return
  data=HTML.encode();self.send_response(200);self.send_header('Content-Type','text/html; charset=utf-8');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
 def do_POST(self):
  if self.path!='/control':self.send_error(404);return
  if self.headers.get('Origin') not in (None,'http://127.0.0.1:18765','http://localhost:18765'):self.send_error(403);return
  try:
   n=int(self.headers.get('Content-Length','0'))
   if not 0<n<1024:raise ValueError('请求长度无效')
   key=json.loads(self.rfile.read(n))['key']
   if key=='info':message=shell('192.168.1.100','getprop ro.product.model; getprop ro.build.version.release').strip()
   elif key in KEYS:message=shell('192.168.1.100','input keyevent '+str(KEYS[key])).strip() or '已发送 '+key+'，请查看投影画面'
   else:raise ValueError('未知按键')
   result={'ok':True,'message':message}
  except Exception as e:result={'ok':False,'message':str(e)}
  data=json.dumps(result,ensure_ascii=False).encode();self.send_response(200);self.send_header('Content-Type','application/json; charset=utf-8');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
if __name__=='__main__':
 print('遥控器：http://127.0.0.1:18765',flush=True)
 ThreadingHTTPServer(('127.0.0.1',18765),Handler).serve_forever()
