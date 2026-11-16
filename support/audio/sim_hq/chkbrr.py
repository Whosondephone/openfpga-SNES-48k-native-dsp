import sys
exec(open('gen_test.py').read().split("test = sys.argv")[0])
ar=bytes(int(l,16) for l in open('aram.hex'))
src=int(sys.argv[1]); base=ar[0x200+4*src]|ar[0x201+4*src]<<8
p1=p2=0; out=[]; a=base
for blk in range(200):
    h=ar[a]; sh=h>>4; fl=(h>>2)&3
    for j in range(16):
        byte=ar[a+1+j//2]; n=(byte>>4) if j%2==0 else byte&15
        s=brr_decode_sample(n,sh,fl,p1,p2); out.append(s); p2,p1=p1,s
    a = base if h&1 else a+9
hw=[int(l) for l in open('brr.txt')]
# find first index where hw matches start
for i in range(len(hw)):
    if hw[i:i+3]==out[:3]: break
m=[k for k in range(min(len(out),len(hw)-i)) if hw[i+k]!=out[k]]
print("start",i,"mismatches",len(m),"first",m[:5], [ (out[k],hw[i+k]) for k in m[:5]], "headers", [ar[base+9*b]>>2&3 for b in range(4)])
