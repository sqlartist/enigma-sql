import csv, re, math, sys
import matplotlib; matplotlib.use('Agg')
import matplotlib.pyplot as plt
from mpl_toolkits.mplot3d.art3d import Line3DCollection
import numpy as np
SURF='#fcfcfb'; INK='#0b0b0b'; INK2='#52514e'; MUTED='#b9b8b2'; BLUE='#2a78d6'; ORANGE='#eb6834'; AQUA='#1baf7a'
plt.rcParams.update({'font.family':'DejaVu Sans','text.color':INK,'axes.labelcolor':INK2,'xtick.color':INK2,'ytick.color':INK2,'axes.edgecolor':MUTED})
def coords(wkt):
    body=re.sub(r'^[A-Z ]+\(','',wkt.strip()).rstrip(')')
    return np.array([[float(v) for v in p.split()] for p in body.split(',')])
A='ABCDEFGHIJKLMNOPQRSTUVWXYZ'
def ang(p): return math.pi/2-p*2*math.pi/26
# ---------- 2D, from SQL Server
rows=[l.rstrip('\n').split('|') for l in open('images/ss_wires.txt') if l.startswith(('W|','P|'))]
wires=[(int(r[1]),int(r[2]),int(r[3]),coords(r[4])) for r in rows if r[0]=='W']
path=[coords(r[4]) for r in rows if r[0]=='P'][0]
def rings(ax,radii,labels=True):
    t=np.linspace(0,2*math.pi,400)
    for r in radii: ax.plot(r*np.cos(t),r*np.sin(t),color=MUTED,lw=0.6,zorder=1)
    if labels:
        for p in range(26):
            ax.text(0.72*math.cos(ang(p)),0.72*math.sin(ang(p)),A[p],ha='center',va='center',fontsize=8,color=INK2)
# image 1: one rotor
fig,ax=plt.subplots(figsize=(6,6),dpi=160); fig.patch.set_facecolor(SURF); ax.set_facecolor(SURF)
rot=[w for w in wires if w[0]==1]
# redraw rotor I alone at shift 0 using the run script geometry: use slot1 from the export (rotor V); instead draw from wiring
W='EKMFLGDQVZNTOWYHXUSPAIBRCJ'
def wire(r1,p1,r2,p2):
    d=((p2-p1+13)%26)-13; pts=[]
    for k in range(9):
        p=p1+d*k/8; r=r1+(r2-r1)*k/8; pts.append((r*math.cos(ang(p)),r*math.sin(ang(p))))
    return np.array(pts)
t=np.linspace(0,2*math.pi,400)
for r in (2,3): ax.plot(r*np.cos(t),r*np.sin(t),color=MUTED,lw=0.8)
for c in range(26):
    w=wire(2,c,3,A.index(W[c])); hl=(c==0)
    ax.plot(w[:,0],w[:,1],color=ORANGE if hl else BLUE,lw=2.2 if hl else 1.0,alpha=1 if hl else 0.7,zorder=3 if hl else 2)
    for r,lab in ((2,1.72),(3,3.3)):
        ax.plot(r*math.cos(ang(c)),r*math.sin(ang(c)),'o',ms=4,color=INK,zorder=4)
        ax.text(lab*math.cos(ang(c)),lab*math.sin(ang(c)),A[c],ha='center',va='center',fontsize=8,color=INK2)
ax.text(0,0.35,'contacts (inner ring)',ha='center',fontsize=9,color=INK2)
ax.text(0,-0.15,'pins (outer ring)',ha='center',fontsize=9,color=INK2)
ax.text(0,-0.65,'A → E highlighted',ha='center',fontsize=9,color=ORANGE)
ax.set_title('Rotor I: 26 POINTs a side, 26 LINESTRINGs between',fontsize=11,color=INK,loc='left')
ax.set_aspect('equal'); ax.axis('off'); plt.tight_layout(); plt.savefig('images/01-rotor-ring.png',facecolor=SURF); plt.close()
# image 2: whole machine + one keypress
fig,ax=plt.subplots(figsize=(7.5,7.5),dpi=160); fig.patch.set_facecolor(SURF); ax.set_facecolor(SURF)
for r in (1,2,3,4,5): ax.plot(r*np.cos(t),r*np.sin(t),color=MUTED,lw=0.6)
for s,_,_,g in wires: ax.plot(g[:,0],g[:,1],color='#c9c8c2',lw=0.5,zorder=1)
ax.plot(path[:,0],path[:,1],color=ORANGE,lw=2.4,zorder=5)
ax.plot(*path[0],'o',color=BLUE,ms=8,zorder=6); ax.plot(*path[-1],'o',color=AQUA,ms=8,zorder=6)
for p in range(26): ax.text(0.78*math.cos(ang(p)),0.78*math.sin(ang(p)),A[p],ha='center',va='center',fontsize=7,color=INK2)
for r,lab in ((1.5,'plugboard'),(2.5,'right (V)'),(3.5,'middle (IV)'),(4.5,'left (II)'),(5.45,'reflector B')):
    ax.text(r*math.cos(math.radians(-62)),r*math.sin(math.radians(-62)),lab,fontsize=8,color=INK2,ha='center',va='center',rotation=28,bbox=dict(fc=SURF,ec='none',pad=0.5))
ax.annotate('key E',path[0],xytext=(-1.6,2.0),color=BLUE,fontsize=9,arrowprops=dict(arrowstyle='-',color=BLUE,lw=0.8))
ax.annotate('lamp A',path[-1],xytext=(1.2,2.0),color=AQUA,fontsize=9,arrowprops=dict(arrowstyle='-',color=AQUA,lw=0.8))
ax.set_title('One keypress in SQL Server: nine wires, one LINESTRING\n(Barbarossa key, first letter: E lights A)',fontsize=11,loc='left')
ax.set_aspect('equal'); ax.axis('off'); plt.tight_layout(); plt.savefig('images/02-keypress-2d.png',facecolor=SURF); plt.close()
# image 3: 3D from PostGIS
w3=[(r[0],coords(r[1])) for r in csv.reader(open('images/wires.csv'))]
p3=[coords(r[2]) for r in csv.reader(open('images/keypress.csv'))][0]
fig=plt.figure(figsize=(9,6),dpi=160); fig.patch.set_facecolor(SURF)
ax=fig.add_subplot(projection='3d'); ax.set_facecolor(SURF)
th=np.linspace(0,2*math.pi,80)
for x0,x1,lab in ((0,1,'left II'),(1,2,'middle IV'),(2,3,'right V'),(3,4,'plugboard')):
    for x in (x0+0.03,x1-0.03): ax.plot([x]*80,np.cos(th),np.sin(th),color=MUTED,lw=0.7)
    ax.text((x0+x1)/2,0,1.35,lab,fontsize=8,color=INK2,ha='center')
ax.text(-0.3,0,1.35,'reflector',fontsize=8,color=INK2,ha='center')
segs=[g for _,g in w3]; ax.add_collection3d(Line3DCollection(segs,colors='#cfcec8',linewidths=0.4))
ax.plot(p3[:,0],p3[:,1],p3[:,2],color=ORANGE,lw=2.4)
ax.scatter(*p3[0],color=BLUE,s=40,depthshade=False); ax.scatter(*p3[-1],color=AQUA,s=40,depthshade=False)
ax.text(*(p3[0]+[0.25,0,0.1]),'key E',color=BLUE,fontsize=9); ax.text(*(p3[-1]+[-0.1,0,0.35]),'lamp A',color=AQUA,fontsize=9)
ax.set_xlim(-0.5,4.3); ax.set_ylim(-1.3,1.3); ax.set_zlim(-1.3,1.3); ax.set_box_aspect((4.8,2.6,2.6))
ax.view_init(elev=22,azim=-62); ax.set_axis_off()
ax.set_title('The same keypress in PostGIS: one LINESTRING Z, 73 points',fontsize=11,loc='left',color=INK)
plt.tight_layout(); plt.savefig('images/03-keypress-3d.png',facecolor=SURF,bbox_inches='tight',pad_inches=0.1); plt.close()
# image 4: bombe funnel (SQL Server log)
steps=[('guess N=?',27418560),('N-X @5',25394072),('N-X @13 (loop)',1002533),('N-G @14',817939),('G-B @7',579860),('X-U @15',353914),('U-D @1',183289),('U-K @3',78595),('D-L @4',27553),('L-R @11',7683),('R-A @6',1679),('A-E @0',297),('E-S @9',45),('U-C @12',4),('N-P @18',1)]
fig,ax=plt.subplots(figsize=(8,4.6),dpi=160); fig.patch.set_facecolor(SURF); ax.set_facecolor(SURF)
y=np.arange(len(steps))
ax.barh(y,[v for _,v in steps],color=[ORANGE if 'loop' in s else BLUE for s,_ in steps],height=0.7)
ax.set_xscale('log'); ax.invert_yaxis(); ax.set_yticks(y,[s for s,_ in steps],fontsize=8)
for i,(s,v) in enumerate(steps): ax.text(v*1.15,i,f'{v:,}',va='center',fontsize=7.5,color=INK)
ax.set_xlim(0.8,2e8); ax.set_xlabel('candidate settings left (log scale)',fontsize=9)
for sp in ('top','right'): ax.spines[sp].set_visible(False)
ax.grid(axis='x',color='#e6e5e0',lw=0.6); ax.set_axisbelow(True)
ax.set_title('The Bombe in SQL: 27.4 million guesses, one stop',fontsize=11,loc='left')
plt.tight_layout(); plt.savefig('images/04-bombe-funnel.png',facecolor=SURF); plt.close()
# image 5: menu graph
crib='AUFKLXABTEILUNGXVONX'; C='EDPUDNRGYSZRCXNUYTPO'
E=[(crib[i],C[i],i) for i in range(20)]
import collections
nodes=sorted(set([a for a,b,i in E]+[b for a,b,i in E]))
G=collections.defaultdict(list)
for a,b,i in E: G[a].append(b); G[b].append(a)
pos={k:np.array(v,dtype=float) for k,v in dict(X=(0,0),N=(0,-1.6),U=(-1.4,1.0),K=(-1.4,2.3),C=(-0.2,2.1),D=(-2.8,1.0),L=(-4.2,1.0),R=(-5.6,1.0),
 A=(-5.6,-0.4),E=(-5.6,-1.8),S=(-4.2,-1.8),O=(1.4,0.6),T=(2.8,0.6),Y=(4.2,0.6),V=(5.6,0.6),G=(-1.2,-2.8),B=(-2.6,-2.8),P=(1.2,-2.8),F=(2.6,-2.8),I=(4.2,-2.2),Z=(5.6,-2.2)).items()}
fig,ax=plt.subplots(figsize=(8,4.6),dpi=160); fig.patch.set_facecolor(SURF); ax.set_facecolor(SURF)
for a,b,i in E:
    pa,pb=pos[a],pos[b]
    if {a,b}=={'X','N'}:
        off=np.array([-(pb-pa)[1],(pb-pa)[0]]); off=off/np.linalg.norm(off)*0.25*(1 if i==5 else 1)
        pa=pa+off; pb=pb+off; col=ORANGE; lw=2.2
    else: col=MUTED; lw=1.2
    ax.plot([pa[0],pb[0]],[pa[1],pb[1]],color=col,lw=lw,zorder=1)
    m=(pa+pb)/2; ax.text(m[0],m[1],str(i),fontsize=7,color=INK2,ha='center',va='center',bbox=dict(fc=SURF,ec='none',pad=0.3),zorder=2)
for n in nodes:
    ax.scatter(*pos[n],s=330,color=SURF,edgecolors=BLUE if n!='N' else ORANGE,linewidths=1.6,zorder=3)
    ax.text(*pos[n],n,ha='center',va='center',fontsize=9,zorder=4,color=INK)
ax.set_title('The menu: crib AUFKLXABTEILUNGXVONX against the ciphertext\n(edge number = position in the message; the X-N-X loop in orange)',fontsize=10,loc='left')
ax.set_aspect('equal'); ax.axis('off'); plt.tight_layout(); plt.savefig('images/05-menu.png',facecolor=SURF,bbox_inches='tight',pad_inches=0.15); plt.close()
print('ok')
