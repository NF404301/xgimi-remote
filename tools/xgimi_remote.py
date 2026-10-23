#!/usr/bin/env python3
"""Minimal standard-library ADB remote for this projector."""
import argparse
import socket
import struct

KEYS = {'up':19,'down':20,'left':21,'right':22,'ok':23,'back':4,'home':3,'menu':82,'volume-up':24,'volume-down':25,'mute':164,'play-pause':85}

def shell(host, command):
    with socket.create_connection((host,5555),5) as s:
        s.settimeout(15)
        def read(n):
            out=b''
            while len(out)<n:
                chunk=s.recv(n-len(out))
                if not chunk: raise ConnectionError('设备关闭了连接')
                out+=chunk
            return out
        def send(name,a=0,b=0,data=b''):
            c=int.from_bytes(name,'little')
            s.sendall(struct.pack('<6I',c,a,b,len(data),sum(data)&0xffffffff,c^0xffffffff)+data)
        def recv():
            c,a,b,n,checksum,magic=struct.unpack('<6I',read(24))
            if magic != c^0xffffffff or n>16*1024*1024: raise RuntimeError('无效 ADB 数据包')
            return c.to_bytes(4,'little'),a,b,read(n)
        send(b'CNXN',0x1000000,4096,b'host::\0')
        c,a,b,p=recv()
        if c==b'AUTH': raise RuntimeError('设备要求 ADB 授权，请使用官方 adb 完成配对')
        if c!=b'CNXN': raise RuntimeError('不是预期的 ADB 服务')
        send(b'OPEN',1,0,('shell:'+command+'\0').encode())
        result=bytearray()
        while True:
            c,a,b,p=recv()
            if c==b'WRTE':
                result.extend(p);send(b'OKAY',1,a)
            elif c==b'CLSE':
                send(b'CLSE',1,a);break
            elif c!=b'OKAY': raise RuntimeError('意外 ADB 响应：'+repr(c))
        return result.decode('utf-8',errors='replace')

def main():
    p=argparse.ArgumentParser(description='极米 Wi-Fi 遥控器（ADB）')
    p.add_argument('--host',default='192.168.1.100')
    p.add_argument('action',choices=['info','interactive']+list(KEYS))
    args=p.parse_args()
    try:
        if args.action=='info':
            print(shell(args.host,'getprop ro.product.model; getprop ro.product.device; getprop ro.build.version.release; id'))
        elif args.action=='interactive':
            print('输入按键名，回车发送；quit 退出。\n'+', '.join(KEYS))
            while True:
                key=input('遥控> ').strip()
                if key in ('quit','exit'): break
                if key not in KEYS: print('未知按键');continue
                print(shell(args.host,'input keyevent '+str(KEYS[key])) or '已发送')
        else:
            print(shell(args.host,'input keyevent '+str(KEYS[args.action])) or '已发送')
    except (OSError,RuntimeError) as e: p.exit(1,str(e)+'\n')
    except (KeyboardInterrupt,EOFError): print()

if __name__=='__main__': main()
