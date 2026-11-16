import numpy as np, sys
CLK=21477270.0
src_period={0:64,1:32,2:8}
def load(p):
    a=np.loadtxt(p); return a[:,0],a[:,1]
def bh(N):
    n=np.arange(N); a=[0.35875,0.48829,0.14128,0.01168]
    return a[0]-a[1]*np.cos(2*np.pi*n/(N-1))+a[2]*np.cos(4*np.pi*n/(N-1))-a[3]*np.cos(6*np.pi*n/(N-1))
def analyse(x, fs, f0):
    x=x-x.mean(); N=len(x); X=np.abs(np.fft.rfft(x*bh(N)))**2
    f=np.arange(len(X))*fs/N
    k=np.argmax(X); a,b,c=np.log(X[k-1:k+2]+1e-30); p=0.5*(a-c)/(a-2*b+c)
    fpk=(k+p)*fs/N
    fund=np.abs(f-fpk)<=8*fs/N
    harm=np.zeros_like(fund)
    for h in range(1,200):
        if h*f0 > fs/2: break
        harm|=np.abs(f-h*f0)<=8*fs/N
    sig=X[fund].sum(); tot=X[3:].sum()
    thdn=10*np.log10((tot-sig)/sig)
    inh=10*np.log10(X[~harm][3:].sum()/sig)
    spur=10*np.log10(X[~harm][3:].max()/X[k])
    aud=(~harm)&(f<20000); aud[:3]=False
    inh20=10*np.log10(X[aud].sum()/sig)
    return fpk,thdn,inh20,spur
src=int(sys.argv[1]); P=int(sys.argv[2],0)
th,hw=load('hw.txt'); tq,hq=load('hq.txt'); tr,rs=load('rs.txt')
fs_dsp=CLK/np.mean(np.diff(th[1000:]))
f0=fs_dsp*P/4096/src_period[src]
# OLD: original core holds the latest DSP sample at each 48k request
treq=tq  # request instants ~ output times (same lag for all)
idx=np.searchsorted(th,treq)-1
old=hw[np.clip(idx,0,None)]
skip=3000
res={}
for name,x in [('old',old),('resampler',rs),('native48',hq)]:
    res[name]=analyse(x[skip:skip+2**15],48000.0,f0)
print(f"src{src} P=0x{P:04X} expected {f0:9.3f} Hz (DSP fs {fs_dsp:.2f})")
for k,(fp,t,i,s) in res.items():
    print(f"  {k:10s} pitch {fp:9.3f} Hz  THD+N {t:6.1f} dB  inharmonic<20k {i:6.1f} dB  worst spur {s:6.1f} dB")
