import sys
hw=[tuple(map(int,l.split())) for l in open('hw.txt')]
hq=[tuple(map(int,l.split())) for l in open('hq.txt')]
for lag in range(14,20):
    n=0;bad=0;first=None
    for j in range(lag+200,len(hq)):
        a=hq[j][1:];b=hw[j-lag][1:]
        n+=1
        if a!=b:
            bad+=1
            if first is None: first=(j,a,b)
    print("lag",lag,"compared",n,"mismatch",bad,"first",first)
