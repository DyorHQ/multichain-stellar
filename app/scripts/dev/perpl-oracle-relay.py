"""Replay Perpl's keeper oracle updates (execPerpOps) from Monad mainnet onto the local anvil fork by impersonating
the keeper, so the fork's reference prices stay fresh (refPriceMaxAgeSec = 60) during app rehearsals.
Usage: python3 scripts/dev/perpl-oracle-relay.py once [perpId]   -> replay the latest update carrying perpId (default 1) and exit
       python3 scripts/dev/perpl-oracle-relay.py loop [perpIds]  -> follow mainnet and replay every keeper tx that carries one of them"""
import json, subprocess, sys, time, urllib.request
MAIN='https://rpc3.monad.xyz'; FORK='http://127.0.0.1:8545'
EX='0x34b6552d57a35a1d042ccae1951bd1c370112a6f'; SEL='0x5bf9264c'
def rpc(url, method, params):
    req=urllib.request.Request(url, data=json.dumps({'jsonrpc':'2.0','id':1,'method':method,'params':params}).encode(), headers={'content-type':'application/json'})
    return json.loads(urllib.request.urlopen(req, timeout=30).read())['result']
def ops(inp):
    w=[inp[10:][i:i+64] for i in range(0,len(inp)-10,64)]
    cnt=int(w[1],16); out=[]
    for i in range(cnt):
        off=int(w[2+i],16)//32+2
        out.append((int(w[off+1],16), int(w[off+2],16), int(w[off+3],16)))  # perpId, opType, price
    return out
impersonated=set()
def replay(tx):
    frm=tx['from']
    if frm not in impersonated:
        rpc(FORK,'anvil_impersonateAccount',[frm]); impersonated.add(frm)
        bal=int(rpc(FORK,'eth_getBalance',[frm,'latest']),16)
        if bal < 10**18: rpc(FORK,'anvil_setBalance',[frm, hex(10**19)])
    h=rpc(FORK,'eth_sendTransaction',[{'from':frm,'to':EX,'data':tx['input'],'gas':hex(3_000_000)}])
    for _ in range(60):
        r=rpc(FORK,'eth_getTransactionReceipt',[h])
        if r: return h, int(r['status'],16)
        time.sleep(0.5)
    return h, None
def scan_range(a, b):
    """Keeper txs in blocks a..b (inclusive), fetched eight blocks per HTTP request so the relay keeps up with Monad."""
    out=[]
    for start in range(a, b+1, 8):
        batch=[{'jsonrpc':'2.0','id':i,'method':'eth_getBlockByNumber','params':[hex(n),True]} for i,n in enumerate(range(start, min(start+8, b+1)))]
        req=urllib.request.Request(MAIN, data=json.dumps(batch).encode(), headers={'content-type':'application/json'})
        res=json.loads(urllib.request.urlopen(req, timeout=30).read())
        for r in sorted(res, key=lambda r: r['id']):
            blk=r.get('result')
            if not blk: continue
            out += [tx for tx in blk['transactions'] if (tx.get('to') or '').lower()==EX and tx['input'].startswith(SEL)]
    return out
def scan(n): return scan_range(n, n)
mode=sys.argv[1] if len(sys.argv)>1 else 'once'
want=set(int(x) for x in sys.argv[2].split(',')) if len(sys.argv)>2 else {1}
latest=int(rpc(MAIN,'eth_blockNumber',[]),16)
if mode=='once':
    for n in range(latest, latest-2000, -1):
        for tx in scan(n):
            o=ops(tx['input'])
            if any(p in want and t==0 for p,t,_ in o):
                print('replaying', tx['hash'], 'block', n, 'ops', o, flush=True)
                print('result', replay(tx), flush=True); sys.exit(0)
    print('no update found'); sys.exit(1)
else:
    last=latest
    print('following mainnet from', last, 'for perps', sorted(want), flush=True)
    while True:
        try:
            head=int(rpc(MAIN,'eth_blockNumber',[]),16)
            if head > last:
                for tx in scan_range(last+1, head):
                    o=ops(tx['input'])
                    if any(p in want for p,_,_ in o):
                        h,st=replay(tx)
                        print(time.strftime('%H:%M:%S'), 'replayed', tx['hash'][:12], 'from block', int(tx['blockNumber'],16), 'lag', head-int(tx['blockNumber'],16), 'blocks; ops', o, 'status', st, flush=True)
                last=head
        except Exception as e:
            print('error', e, flush=True)
        time.sleep(1)
