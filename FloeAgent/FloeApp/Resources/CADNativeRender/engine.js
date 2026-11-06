(()=>{var Mm=Object.defineProperty;var Tm=(i,e)=>{for(var t in e)Mm(i,t,{get:e[t],enumerable:!0})};var sf=0,gu=1,af=2;var xu=1,of=2,jn=3,Mn=0,Zt=1,fn=2,$t=0,Gn=1,ta=2,vu=3,_u=4,cf=5,Ei=100,lf=101,uf=102,hf=103,ff=104,df=200,pf=201,mf=202,gf=203,no=204,io=205,xf=206,vf=207,_f=208,yf=209,bf=210,Sf=211,Mf=212,Tf=213,wf=214,Ao=0,Eo=1,Co=2,er=3,Ro=4,Io=5,Po=6,Do=7,yu=0,Af=1,Ef=2,qn=0,Cf=1,Rf=2,If=3,Fo=4,Pf=5,Df=6,Ff=7;var bu=300,ar=301,or=302,ei=303,Lo=304,na=306,hn=1e3,Lt=1001,ro=1002,je=1003,Lf=1004;var ia=1005;var ft=1006,No=1007;var mi=1008,Su=1008,dn=1009,Jr=1010,ra=1011,Li=1012,Ni=1013,xn=1014,qe=1015,_t=1016,Uo=1017,Bo=1018,Kr=1020,Mu=35902,Tu=35899,wu=1021,Au=1022,He=1023,kr=1026,Qr=1027,vn=1028,jr=1029,Tn=1030,Ui=1031;var Bi=1033,sa=33776,aa=33777,oa=33778,ca=33779,Oo=35840,zo=35841,ko=35842,Vo=35843,Ho=36196,Go=37492,Wo=37496,Xo=37808,qo=37809,Yo=37810,Zo=37811,$o=37812,Jo=37813,Ko=37814,Qo=37815,jo=37816,ec=37817,tc=37818,nc=37819,ic=37820,rc=37821,sc=36492,ac=36494,oc=36495,cc=36283,lc=36284,uc=36285,hc=36286;var Ls=2300,so=2301,to=2302,au=2400,ou=2401,cu=2402;var Nf=3200,Uf=3201;var Eu=0,Bf=1,gi="",ln="srgb",Gt="srgb-linear",Ns="linear",bt="srgb";var Qi=7680;var lu=519,Of=512,zf=513,kf=514,Cu=515,Vf=516,Hf=517,Gf=518,Wf=519,uu=35044;var Ru="300 es",Hn=2e3,Us=2001;function Iu(i){for(let e=i.length-1;e>=0;--e)if(i[e]>=65535)return!0;return!1}function Vr(i){return document.createElementNS("http://www.w3.org/1999/xhtml",i)}function Xf(){let i=Vr("canvas");return i.style.display="block",i}var Bh={},Hr=null;function Pu(...i){let e="THREE."+i.shift();Hr?Hr("log",e,...i):console.log(e,...i)}function Ze(...i){let e="THREE."+i.shift();Hr?Hr("warn",e,...i):console.warn(e,...i)}function ut(...i){let e="THREE."+i.shift();Hr?Hr("error",e,...i):console.error(e,...i)}function Gr(...i){let e=i.join(" ");e in Bh||(Bh[e]=!0,Ze(...i))}function qf(i,e,t){return new Promise(function(n,r){function s(){switch(i.clientWaitSync(e,i.SYNC_FLUSH_COMMANDS_BIT,0)){case i.WAIT_FAILED:r();break;case i.TIMEOUT_EXPIRED:setTimeout(s,t);break;default:n()}}setTimeout(s,t)})}var di=class{addEventListener(e,t){this._listeners===void 0&&(this._listeners={});let n=this._listeners;n[e]===void 0&&(n[e]=[]),n[e].indexOf(t)===-1&&n[e].push(t)}hasEventListener(e,t){let n=this._listeners;return n===void 0?!1:n[e]!==void 0&&n[e].indexOf(t)!==-1}removeEventListener(e,t){let n=this._listeners;if(n===void 0)return;let r=n[e];if(r!==void 0){let s=r.indexOf(t);s!==-1&&r.splice(s,1)}}dispatchEvent(e){let t=this._listeners;if(t===void 0)return;let n=t[e.type];if(n!==void 0){e.target=this;let r=n.slice(0);for(let s=0,a=r.length;s<a;s++)r[s].call(this,e);e.target=null}}},on=["00","01","02","03","04","05","06","07","08","09","0a","0b","0c","0d","0e","0f","10","11","12","13","14","15","16","17","18","19","1a","1b","1c","1d","1e","1f","20","21","22","23","24","25","26","27","28","29","2a","2b","2c","2d","2e","2f","30","31","32","33","34","35","36","37","38","39","3a","3b","3c","3d","3e","3f","40","41","42","43","44","45","46","47","48","49","4a","4b","4c","4d","4e","4f","50","51","52","53","54","55","56","57","58","59","5a","5b","5c","5d","5e","5f","60","61","62","63","64","65","66","67","68","69","6a","6b","6c","6d","6e","6f","70","71","72","73","74","75","76","77","78","79","7a","7b","7c","7d","7e","7f","80","81","82","83","84","85","86","87","88","89","8a","8b","8c","8d","8e","8f","90","91","92","93","94","95","96","97","98","99","9a","9b","9c","9d","9e","9f","a0","a1","a2","a3","a4","a5","a6","a7","a8","a9","aa","ab","ac","ad","ae","af","b0","b1","b2","b3","b4","b5","b6","b7","b8","b9","ba","bb","bc","bd","be","bf","c0","c1","c2","c3","c4","c5","c6","c7","c8","c9","ca","cb","cc","cd","ce","cf","d0","d1","d2","d3","d4","d5","d6","d7","d8","d9","da","db","dc","dd","de","df","e0","e1","e2","e3","e4","e5","e6","e7","e8","e9","ea","eb","ec","ed","ee","ef","f0","f1","f2","f3","f4","f5","f6","f7","f8","f9","fa","fb","fc","fd","fe","ff"];var Ll=Math.PI/180,Bs=180/Math.PI;function la(){let i=Math.random()*4294967295|0,e=Math.random()*4294967295|0,t=Math.random()*4294967295|0,n=Math.random()*4294967295|0;return(on[i&255]+on[i>>8&255]+on[i>>16&255]+on[i>>24&255]+"-"+on[e&255]+on[e>>8&255]+"-"+on[e>>16&15|64]+on[e>>24&255]+"-"+on[t&63|128]+on[t>>8&255]+"-"+on[t>>16&255]+on[t>>24&255]+on[n&255]+on[n>>8&255]+on[n>>16&255]+on[n>>24&255]).toLowerCase()}function Ke(i,e,t){return Math.max(e,Math.min(t,i))}function wm(i,e){return(i%e+e)%e}function Nl(i,e,t){return(1-t)*i+t*e}function Cs(i,e){switch(e.constructor){case Float32Array:return i;case Uint32Array:return i/4294967295;case Uint16Array:return i/65535;case Uint8Array:return i/255;case Int32Array:return Math.max(i/2147483647,-1);case Int16Array:return Math.max(i/32767,-1);case Int8Array:return Math.max(i/127,-1);default:throw new Error("Invalid component type.")}}function bn(i,e){switch(e.constructor){case Float32Array:return i;case Uint32Array:return Math.round(i*4294967295);case Uint16Array:return Math.round(i*65535);case Uint8Array:return Math.round(i*255);case Int32Array:return Math.round(i*2147483647);case Int16Array:return Math.round(i*32767);case Int8Array:return Math.round(i*127);default:throw new Error("Invalid component type.")}}var Le=class i{constructor(e=0,t=0){i.prototype.isVector2=!0,this.x=e,this.y=t}get width(){return this.x}set width(e){this.x=e}get height(){return this.y}set height(e){this.y=e}set(e,t){return this.x=e,this.y=t,this}setScalar(e){return this.x=e,this.y=e,this}setX(e){return this.x=e,this}setY(e){return this.y=e,this}setComponent(e,t){switch(e){case 0:this.x=t;break;case 1:this.y=t;break;default:throw new Error("index is out of range: "+e)}return this}getComponent(e){switch(e){case 0:return this.x;case 1:return this.y;default:throw new Error("index is out of range: "+e)}}clone(){return new this.constructor(this.x,this.y)}copy(e){return this.x=e.x,this.y=e.y,this}add(e){return this.x+=e.x,this.y+=e.y,this}addScalar(e){return this.x+=e,this.y+=e,this}addVectors(e,t){return this.x=e.x+t.x,this.y=e.y+t.y,this}addScaledVector(e,t){return this.x+=e.x*t,this.y+=e.y*t,this}sub(e){return this.x-=e.x,this.y-=e.y,this}subScalar(e){return this.x-=e,this.y-=e,this}subVectors(e,t){return this.x=e.x-t.x,this.y=e.y-t.y,this}multiply(e){return this.x*=e.x,this.y*=e.y,this}multiplyScalar(e){return this.x*=e,this.y*=e,this}divide(e){return this.x/=e.x,this.y/=e.y,this}divideScalar(e){return this.multiplyScalar(1/e)}applyMatrix3(e){let t=this.x,n=this.y,r=e.elements;return this.x=r[0]*t+r[3]*n+r[6],this.y=r[1]*t+r[4]*n+r[7],this}min(e){return this.x=Math.min(this.x,e.x),this.y=Math.min(this.y,e.y),this}max(e){return this.x=Math.max(this.x,e.x),this.y=Math.max(this.y,e.y),this}clamp(e,t){return this.x=Ke(this.x,e.x,t.x),this.y=Ke(this.y,e.y,t.y),this}clampScalar(e,t){return this.x=Ke(this.x,e,t),this.y=Ke(this.y,e,t),this}clampLength(e,t){let n=this.length();return this.divideScalar(n||1).multiplyScalar(Ke(n,e,t))}floor(){return this.x=Math.floor(this.x),this.y=Math.floor(this.y),this}ceil(){return this.x=Math.ceil(this.x),this.y=Math.ceil(this.y),this}round(){return this.x=Math.round(this.x),this.y=Math.round(this.y),this}roundToZero(){return this.x=Math.trunc(this.x),this.y=Math.trunc(this.y),this}negate(){return this.x=-this.x,this.y=-this.y,this}dot(e){return this.x*e.x+this.y*e.y}cross(e){return this.x*e.y-this.y*e.x}lengthSq(){return this.x*this.x+this.y*this.y}length(){return Math.sqrt(this.x*this.x+this.y*this.y)}manhattanLength(){return Math.abs(this.x)+Math.abs(this.y)}normalize(){return this.divideScalar(this.length()||1)}angle(){return Math.atan2(-this.y,-this.x)+Math.PI}angleTo(e){let t=Math.sqrt(this.lengthSq()*e.lengthSq());if(t===0)return Math.PI/2;let n=this.dot(e)/t;return Math.acos(Ke(n,-1,1))}distanceTo(e){return Math.sqrt(this.distanceToSquared(e))}distanceToSquared(e){let t=this.x-e.x,n=this.y-e.y;return t*t+n*n}manhattanDistanceTo(e){return Math.abs(this.x-e.x)+Math.abs(this.y-e.y)}setLength(e){return this.normalize().multiplyScalar(e)}lerp(e,t){return this.x+=(e.x-this.x)*t,this.y+=(e.y-this.y)*t,this}lerpVectors(e,t,n){return this.x=e.x+(t.x-e.x)*n,this.y=e.y+(t.y-e.y)*n,this}equals(e){return e.x===this.x&&e.y===this.y}fromArray(e,t=0){return this.x=e[t],this.y=e[t+1],this}toArray(e=[],t=0){return e[t]=this.x,e[t+1]=this.y,e}fromBufferAttribute(e,t){return this.x=e.getX(t),this.y=e.getY(t),this}rotateAround(e,t){let n=Math.cos(t),r=Math.sin(t),s=this.x-e.x,a=this.y-e.y;return this.x=s*n-a*r+e.x,this.y=s*r+a*n+e.y,this}random(){return this.x=Math.random(),this.y=Math.random(),this}*[Symbol.iterator](){yield this.x,yield this.y}},Wn=class{constructor(e=0,t=0,n=0,r=1){this.isQuaternion=!0,this._x=e,this._y=t,this._z=n,this._w=r}static slerpFlat(e,t,n,r,s,a,o){let c=n[r+0],u=n[r+1],f=n[r+2],h=n[r+3],l=s[a+0],p=s[a+1],g=s[a+2],b=s[a+3];if(o<=0){e[t+0]=c,e[t+1]=u,e[t+2]=f,e[t+3]=h;return}if(o>=1){e[t+0]=l,e[t+1]=p,e[t+2]=g,e[t+3]=b;return}if(h!==b||c!==l||u!==p||f!==g){let m=c*l+u*p+f*g+h*b;m<0&&(l=-l,p=-p,g=-g,b=-b,m=-m);let d=1-o;if(m<.9995){let _=Math.acos(m),y=Math.sin(_);d=Math.sin(d*_)/y,o=Math.sin(o*_)/y,c=c*d+l*o,u=u*d+p*o,f=f*d+g*o,h=h*d+b*o}else{c=c*d+l*o,u=u*d+p*o,f=f*d+g*o,h=h*d+b*o;let _=1/Math.sqrt(c*c+u*u+f*f+h*h);c*=_,u*=_,f*=_,h*=_}}e[t]=c,e[t+1]=u,e[t+2]=f,e[t+3]=h}static multiplyQuaternionsFlat(e,t,n,r,s,a){let o=n[r],c=n[r+1],u=n[r+2],f=n[r+3],h=s[a],l=s[a+1],p=s[a+2],g=s[a+3];return e[t]=o*g+f*h+c*p-u*l,e[t+1]=c*g+f*l+u*h-o*p,e[t+2]=u*g+f*p+o*l-c*h,e[t+3]=f*g-o*h-c*l-u*p,e}get x(){return this._x}set x(e){this._x=e,this._onChangeCallback()}get y(){return this._y}set y(e){this._y=e,this._onChangeCallback()}get z(){return this._z}set z(e){this._z=e,this._onChangeCallback()}get w(){return this._w}set w(e){this._w=e,this._onChangeCallback()}set(e,t,n,r){return this._x=e,this._y=t,this._z=n,this._w=r,this._onChangeCallback(),this}clone(){return new this.constructor(this._x,this._y,this._z,this._w)}copy(e){return this._x=e.x,this._y=e.y,this._z=e.z,this._w=e.w,this._onChangeCallback(),this}setFromEuler(e,t=!0){let n=e._x,r=e._y,s=e._z,a=e._order,o=Math.cos,c=Math.sin,u=o(n/2),f=o(r/2),h=o(s/2),l=c(n/2),p=c(r/2),g=c(s/2);switch(a){case"XYZ":this._x=l*f*h+u*p*g,this._y=u*p*h-l*f*g,this._z=u*f*g+l*p*h,this._w=u*f*h-l*p*g;break;case"YXZ":this._x=l*f*h+u*p*g,this._y=u*p*h-l*f*g,this._z=u*f*g-l*p*h,this._w=u*f*h+l*p*g;break;case"ZXY":this._x=l*f*h-u*p*g,this._y=u*p*h+l*f*g,this._z=u*f*g+l*p*h,this._w=u*f*h-l*p*g;break;case"ZYX":this._x=l*f*h-u*p*g,this._y=u*p*h+l*f*g,this._z=u*f*g-l*p*h,this._w=u*f*h+l*p*g;break;case"YZX":this._x=l*f*h+u*p*g,this._y=u*p*h+l*f*g,this._z=u*f*g-l*p*h,this._w=u*f*h-l*p*g;break;case"XZY":this._x=l*f*h-u*p*g,this._y=u*p*h-l*f*g,this._z=u*f*g+l*p*h,this._w=u*f*h+l*p*g;break;default:Ze("Quaternion: .setFromEuler() encountered an unknown order: "+a)}return t===!0&&this._onChangeCallback(),this}setFromAxisAngle(e,t){let n=t/2,r=Math.sin(n);return this._x=e.x*r,this._y=e.y*r,this._z=e.z*r,this._w=Math.cos(n),this._onChangeCallback(),this}setFromRotationMatrix(e){let t=e.elements,n=t[0],r=t[4],s=t[8],a=t[1],o=t[5],c=t[9],u=t[2],f=t[6],h=t[10],l=n+o+h;if(l>0){let p=.5/Math.sqrt(l+1);this._w=.25/p,this._x=(f-c)*p,this._y=(s-u)*p,this._z=(a-r)*p}else if(n>o&&n>h){let p=2*Math.sqrt(1+n-o-h);this._w=(f-c)/p,this._x=.25*p,this._y=(r+a)/p,this._z=(s+u)/p}else if(o>h){let p=2*Math.sqrt(1+o-n-h);this._w=(s-u)/p,this._x=(r+a)/p,this._y=.25*p,this._z=(c+f)/p}else{let p=2*Math.sqrt(1+h-n-o);this._w=(a-r)/p,this._x=(s+u)/p,this._y=(c+f)/p,this._z=.25*p}return this._onChangeCallback(),this}setFromUnitVectors(e,t){let n=e.dot(t)+1;return n<1e-8?(n=0,Math.abs(e.x)>Math.abs(e.z)?(this._x=-e.y,this._y=e.x,this._z=0,this._w=n):(this._x=0,this._y=-e.z,this._z=e.y,this._w=n)):(this._x=e.y*t.z-e.z*t.y,this._y=e.z*t.x-e.x*t.z,this._z=e.x*t.y-e.y*t.x,this._w=n),this.normalize()}angleTo(e){return 2*Math.acos(Math.abs(Ke(this.dot(e),-1,1)))}rotateTowards(e,t){let n=this.angleTo(e);if(n===0)return this;let r=Math.min(1,t/n);return this.slerp(e,r),this}identity(){return this.set(0,0,0,1)}invert(){return this.conjugate()}conjugate(){return this._x*=-1,this._y*=-1,this._z*=-1,this._onChangeCallback(),this}dot(e){return this._x*e._x+this._y*e._y+this._z*e._z+this._w*e._w}lengthSq(){return this._x*this._x+this._y*this._y+this._z*this._z+this._w*this._w}length(){return Math.sqrt(this._x*this._x+this._y*this._y+this._z*this._z+this._w*this._w)}normalize(){let e=this.length();return e===0?(this._x=0,this._y=0,this._z=0,this._w=1):(e=1/e,this._x=this._x*e,this._y=this._y*e,this._z=this._z*e,this._w=this._w*e),this._onChangeCallback(),this}multiply(e){return this.multiplyQuaternions(this,e)}premultiply(e){return this.multiplyQuaternions(e,this)}multiplyQuaternions(e,t){let n=e._x,r=e._y,s=e._z,a=e._w,o=t._x,c=t._y,u=t._z,f=t._w;return this._x=n*f+a*o+r*u-s*c,this._y=r*f+a*c+s*o-n*u,this._z=s*f+a*u+n*c-r*o,this._w=a*f-n*o-r*c-s*u,this._onChangeCallback(),this}slerp(e,t){if(t<=0)return this;if(t>=1)return this.copy(e);let n=e._x,r=e._y,s=e._z,a=e._w,o=this.dot(e);o<0&&(n=-n,r=-r,s=-s,a=-a,o=-o);let c=1-t;if(o<.9995){let u=Math.acos(o),f=Math.sin(u);c=Math.sin(c*u)/f,t=Math.sin(t*u)/f,this._x=this._x*c+n*t,this._y=this._y*c+r*t,this._z=this._z*c+s*t,this._w=this._w*c+a*t,this._onChangeCallback()}else this._x=this._x*c+n*t,this._y=this._y*c+r*t,this._z=this._z*c+s*t,this._w=this._w*c+a*t,this.normalize();return this}slerpQuaternions(e,t,n){return this.copy(e).slerp(t,n)}random(){let e=2*Math.PI*Math.random(),t=2*Math.PI*Math.random(),n=Math.random(),r=Math.sqrt(1-n),s=Math.sqrt(n);return this.set(r*Math.sin(e),r*Math.cos(e),s*Math.sin(t),s*Math.cos(t))}equals(e){return e._x===this._x&&e._y===this._y&&e._z===this._z&&e._w===this._w}fromArray(e,t=0){return this._x=e[t],this._y=e[t+1],this._z=e[t+2],this._w=e[t+3],this._onChangeCallback(),this}toArray(e=[],t=0){return e[t]=this._x,e[t+1]=this._y,e[t+2]=this._z,e[t+3]=this._w,e}fromBufferAttribute(e,t){return this._x=e.getX(t),this._y=e.getY(t),this._z=e.getZ(t),this._w=e.getW(t),this._onChangeCallback(),this}toJSON(){return this.toArray()}_onChange(e){return this._onChangeCallback=e,this}_onChangeCallback(){}*[Symbol.iterator](){yield this._x,yield this._y,yield this._z,yield this._w}},k=class i{constructor(e=0,t=0,n=0){i.prototype.isVector3=!0,this.x=e,this.y=t,this.z=n}set(e,t,n){return n===void 0&&(n=this.z),this.x=e,this.y=t,this.z=n,this}setScalar(e){return this.x=e,this.y=e,this.z=e,this}setX(e){return this.x=e,this}setY(e){return this.y=e,this}setZ(e){return this.z=e,this}setComponent(e,t){switch(e){case 0:this.x=t;break;case 1:this.y=t;break;case 2:this.z=t;break;default:throw new Error("index is out of range: "+e)}return this}getComponent(e){switch(e){case 0:return this.x;case 1:return this.y;case 2:return this.z;default:throw new Error("index is out of range: "+e)}}clone(){return new this.constructor(this.x,this.y,this.z)}copy(e){return this.x=e.x,this.y=e.y,this.z=e.z,this}add(e){return this.x+=e.x,this.y+=e.y,this.z+=e.z,this}addScalar(e){return this.x+=e,this.y+=e,this.z+=e,this}addVectors(e,t){return this.x=e.x+t.x,this.y=e.y+t.y,this.z=e.z+t.z,this}addScaledVector(e,t){return this.x+=e.x*t,this.y+=e.y*t,this.z+=e.z*t,this}sub(e){return this.x-=e.x,this.y-=e.y,this.z-=e.z,this}subScalar(e){return this.x-=e,this.y-=e,this.z-=e,this}subVectors(e,t){return this.x=e.x-t.x,this.y=e.y-t.y,this.z=e.z-t.z,this}multiply(e){return this.x*=e.x,this.y*=e.y,this.z*=e.z,this}multiplyScalar(e){return this.x*=e,this.y*=e,this.z*=e,this}multiplyVectors(e,t){return this.x=e.x*t.x,this.y=e.y*t.y,this.z=e.z*t.z,this}applyEuler(e){return this.applyQuaternion(Oh.setFromEuler(e))}applyAxisAngle(e,t){return this.applyQuaternion(Oh.setFromAxisAngle(e,t))}applyMatrix3(e){let t=this.x,n=this.y,r=this.z,s=e.elements;return this.x=s[0]*t+s[3]*n+s[6]*r,this.y=s[1]*t+s[4]*n+s[7]*r,this.z=s[2]*t+s[5]*n+s[8]*r,this}applyNormalMatrix(e){return this.applyMatrix3(e).normalize()}applyMatrix4(e){let t=this.x,n=this.y,r=this.z,s=e.elements,a=1/(s[3]*t+s[7]*n+s[11]*r+s[15]);return this.x=(s[0]*t+s[4]*n+s[8]*r+s[12])*a,this.y=(s[1]*t+s[5]*n+s[9]*r+s[13])*a,this.z=(s[2]*t+s[6]*n+s[10]*r+s[14])*a,this}applyQuaternion(e){let t=this.x,n=this.y,r=this.z,s=e.x,a=e.y,o=e.z,c=e.w,u=2*(a*r-o*n),f=2*(o*t-s*r),h=2*(s*n-a*t);return this.x=t+c*u+a*h-o*f,this.y=n+c*f+o*u-s*h,this.z=r+c*h+s*f-a*u,this}project(e){return this.applyMatrix4(e.matrixWorldInverse).applyMatrix4(e.projectionMatrix)}unproject(e){return this.applyMatrix4(e.projectionMatrixInverse).applyMatrix4(e.matrixWorld)}transformDirection(e){let t=this.x,n=this.y,r=this.z,s=e.elements;return this.x=s[0]*t+s[4]*n+s[8]*r,this.y=s[1]*t+s[5]*n+s[9]*r,this.z=s[2]*t+s[6]*n+s[10]*r,this.normalize()}divide(e){return this.x/=e.x,this.y/=e.y,this.z/=e.z,this}divideScalar(e){return this.multiplyScalar(1/e)}min(e){return this.x=Math.min(this.x,e.x),this.y=Math.min(this.y,e.y),this.z=Math.min(this.z,e.z),this}max(e){return this.x=Math.max(this.x,e.x),this.y=Math.max(this.y,e.y),this.z=Math.max(this.z,e.z),this}clamp(e,t){return this.x=Ke(this.x,e.x,t.x),this.y=Ke(this.y,e.y,t.y),this.z=Ke(this.z,e.z,t.z),this}clampScalar(e,t){return this.x=Ke(this.x,e,t),this.y=Ke(this.y,e,t),this.z=Ke(this.z,e,t),this}clampLength(e,t){let n=this.length();return this.divideScalar(n||1).multiplyScalar(Ke(n,e,t))}floor(){return this.x=Math.floor(this.x),this.y=Math.floor(this.y),this.z=Math.floor(this.z),this}ceil(){return this.x=Math.ceil(this.x),this.y=Math.ceil(this.y),this.z=Math.ceil(this.z),this}round(){return this.x=Math.round(this.x),this.y=Math.round(this.y),this.z=Math.round(this.z),this}roundToZero(){return this.x=Math.trunc(this.x),this.y=Math.trunc(this.y),this.z=Math.trunc(this.z),this}negate(){return this.x=-this.x,this.y=-this.y,this.z=-this.z,this}dot(e){return this.x*e.x+this.y*e.y+this.z*e.z}lengthSq(){return this.x*this.x+this.y*this.y+this.z*this.z}length(){return Math.sqrt(this.x*this.x+this.y*this.y+this.z*this.z)}manhattanLength(){return Math.abs(this.x)+Math.abs(this.y)+Math.abs(this.z)}normalize(){return this.divideScalar(this.length()||1)}setLength(e){return this.normalize().multiplyScalar(e)}lerp(e,t){return this.x+=(e.x-this.x)*t,this.y+=(e.y-this.y)*t,this.z+=(e.z-this.z)*t,this}lerpVectors(e,t,n){return this.x=e.x+(t.x-e.x)*n,this.y=e.y+(t.y-e.y)*n,this.z=e.z+(t.z-e.z)*n,this}cross(e){return this.crossVectors(this,e)}crossVectors(e,t){let n=e.x,r=e.y,s=e.z,a=t.x,o=t.y,c=t.z;return this.x=r*c-s*o,this.y=s*a-n*c,this.z=n*o-r*a,this}projectOnVector(e){let t=e.lengthSq();if(t===0)return this.set(0,0,0);let n=e.dot(this)/t;return this.copy(e).multiplyScalar(n)}projectOnPlane(e){return Ul.copy(this).projectOnVector(e),this.sub(Ul)}reflect(e){return this.sub(Ul.copy(e).multiplyScalar(2*this.dot(e)))}angleTo(e){let t=Math.sqrt(this.lengthSq()*e.lengthSq());if(t===0)return Math.PI/2;let n=this.dot(e)/t;return Math.acos(Ke(n,-1,1))}distanceTo(e){return Math.sqrt(this.distanceToSquared(e))}distanceToSquared(e){let t=this.x-e.x,n=this.y-e.y,r=this.z-e.z;return t*t+n*n+r*r}manhattanDistanceTo(e){return Math.abs(this.x-e.x)+Math.abs(this.y-e.y)+Math.abs(this.z-e.z)}setFromSpherical(e){return this.setFromSphericalCoords(e.radius,e.phi,e.theta)}setFromSphericalCoords(e,t,n){let r=Math.sin(t)*e;return this.x=r*Math.sin(n),this.y=Math.cos(t)*e,this.z=r*Math.cos(n),this}setFromCylindrical(e){return this.setFromCylindricalCoords(e.radius,e.theta,e.y)}setFromCylindricalCoords(e,t,n){return this.x=e*Math.sin(t),this.y=n,this.z=e*Math.cos(t),this}setFromMatrixPosition(e){let t=e.elements;return this.x=t[12],this.y=t[13],this.z=t[14],this}setFromMatrixScale(e){let t=this.setFromMatrixColumn(e,0).length(),n=this.setFromMatrixColumn(e,1).length(),r=this.setFromMatrixColumn(e,2).length();return this.x=t,this.y=n,this.z=r,this}setFromMatrixColumn(e,t){return this.fromArray(e.elements,t*4)}setFromMatrix3Column(e,t){return this.fromArray(e.elements,t*3)}setFromEuler(e){return this.x=e._x,this.y=e._y,this.z=e._z,this}setFromColor(e){return this.x=e.r,this.y=e.g,this.z=e.b,this}equals(e){return e.x===this.x&&e.y===this.y&&e.z===this.z}fromArray(e,t=0){return this.x=e[t],this.y=e[t+1],this.z=e[t+2],this}toArray(e=[],t=0){return e[t]=this.x,e[t+1]=this.y,e[t+2]=this.z,e}fromBufferAttribute(e,t){return this.x=e.getX(t),this.y=e.getY(t),this.z=e.getZ(t),this}random(){return this.x=Math.random(),this.y=Math.random(),this.z=Math.random(),this}randomDirection(){let e=Math.random()*Math.PI*2,t=Math.random()*2-1,n=Math.sqrt(1-t*t);return this.x=n*Math.cos(e),this.y=t,this.z=n*Math.sin(e),this}*[Symbol.iterator](){yield this.x,yield this.y,yield this.z}},Ul=new k,Oh=new Wn,et=class i{constructor(e,t,n,r,s,a,o,c,u){i.prototype.isMatrix3=!0,this.elements=[1,0,0,0,1,0,0,0,1],e!==void 0&&this.set(e,t,n,r,s,a,o,c,u)}set(e,t,n,r,s,a,o,c,u){let f=this.elements;return f[0]=e,f[1]=r,f[2]=o,f[3]=t,f[4]=s,f[5]=c,f[6]=n,f[7]=a,f[8]=u,this}identity(){return this.set(1,0,0,0,1,0,0,0,1),this}copy(e){let t=this.elements,n=e.elements;return t[0]=n[0],t[1]=n[1],t[2]=n[2],t[3]=n[3],t[4]=n[4],t[5]=n[5],t[6]=n[6],t[7]=n[7],t[8]=n[8],this}extractBasis(e,t,n){return e.setFromMatrix3Column(this,0),t.setFromMatrix3Column(this,1),n.setFromMatrix3Column(this,2),this}setFromMatrix4(e){let t=e.elements;return this.set(t[0],t[4],t[8],t[1],t[5],t[9],t[2],t[6],t[10]),this}multiply(e){return this.multiplyMatrices(this,e)}premultiply(e){return this.multiplyMatrices(e,this)}multiplyMatrices(e,t){let n=e.elements,r=t.elements,s=this.elements,a=n[0],o=n[3],c=n[6],u=n[1],f=n[4],h=n[7],l=n[2],p=n[5],g=n[8],b=r[0],m=r[3],d=r[6],_=r[1],y=r[4],M=r[7],w=r[2],A=r[5],I=r[8];return s[0]=a*b+o*_+c*w,s[3]=a*m+o*y+c*A,s[6]=a*d+o*M+c*I,s[1]=u*b+f*_+h*w,s[4]=u*m+f*y+h*A,s[7]=u*d+f*M+h*I,s[2]=l*b+p*_+g*w,s[5]=l*m+p*y+g*A,s[8]=l*d+p*M+g*I,this}multiplyScalar(e){let t=this.elements;return t[0]*=e,t[3]*=e,t[6]*=e,t[1]*=e,t[4]*=e,t[7]*=e,t[2]*=e,t[5]*=e,t[8]*=e,this}determinant(){let e=this.elements,t=e[0],n=e[1],r=e[2],s=e[3],a=e[4],o=e[5],c=e[6],u=e[7],f=e[8];return t*a*f-t*o*u-n*s*f+n*o*c+r*s*u-r*a*c}invert(){let e=this.elements,t=e[0],n=e[1],r=e[2],s=e[3],a=e[4],o=e[5],c=e[6],u=e[7],f=e[8],h=f*a-o*u,l=o*c-f*s,p=u*s-a*c,g=t*h+n*l+r*p;if(g===0)return this.set(0,0,0,0,0,0,0,0,0);let b=1/g;return e[0]=h*b,e[1]=(r*u-f*n)*b,e[2]=(o*n-r*a)*b,e[3]=l*b,e[4]=(f*t-r*c)*b,e[5]=(r*s-o*t)*b,e[6]=p*b,e[7]=(n*c-u*t)*b,e[8]=(a*t-n*s)*b,this}transpose(){let e,t=this.elements;return e=t[1],t[1]=t[3],t[3]=e,e=t[2],t[2]=t[6],t[6]=e,e=t[5],t[5]=t[7],t[7]=e,this}getNormalMatrix(e){return this.setFromMatrix4(e).invert().transpose()}transposeIntoArray(e){let t=this.elements;return e[0]=t[0],e[1]=t[3],e[2]=t[6],e[3]=t[1],e[4]=t[4],e[5]=t[7],e[6]=t[2],e[7]=t[5],e[8]=t[8],this}setUvTransform(e,t,n,r,s,a,o){let c=Math.cos(s),u=Math.sin(s);return this.set(n*c,n*u,-n*(c*a+u*o)+a+e,-r*u,r*c,-r*(-u*a+c*o)+o+t,0,0,1),this}scale(e,t){return this.premultiply(Bl.makeScale(e,t)),this}rotate(e){return this.premultiply(Bl.makeRotation(-e)),this}translate(e,t){return this.premultiply(Bl.makeTranslation(e,t)),this}makeTranslation(e,t){return e.isVector2?this.set(1,0,e.x,0,1,e.y,0,0,1):this.set(1,0,e,0,1,t,0,0,1),this}makeRotation(e){let t=Math.cos(e),n=Math.sin(e);return this.set(t,-n,0,n,t,0,0,0,1),this}makeScale(e,t){return this.set(e,0,0,0,t,0,0,0,1),this}equals(e){let t=this.elements,n=e.elements;for(let r=0;r<9;r++)if(t[r]!==n[r])return!1;return!0}fromArray(e,t=0){for(let n=0;n<9;n++)this.elements[n]=e[n+t];return this}toArray(e=[],t=0){let n=this.elements;return e[t]=n[0],e[t+1]=n[1],e[t+2]=n[2],e[t+3]=n[3],e[t+4]=n[4],e[t+5]=n[5],e[t+6]=n[6],e[t+7]=n[7],e[t+8]=n[8],e}clone(){return new this.constructor().fromArray(this.elements)}},Bl=new et,zh=new et().set(.4123908,.3575843,.1804808,.212639,.7151687,.0721923,.0193308,.1191948,.9505322),kh=new et().set(3.2409699,-1.5373832,-.4986108,-.9692436,1.8759675,.0415551,.0556301,-.203977,1.0569715);function Am(){let i={enabled:!0,workingColorSpace:Gt,spaces:{},convert:function(r,s,a){return this.enabled===!1||s===a||!s||!a||(this.spaces[s].transfer===bt&&(r.r=fi(r.r),r.g=fi(r.g),r.b=fi(r.b)),this.spaces[s].primaries!==this.spaces[a].primaries&&(r.applyMatrix3(this.spaces[s].toXYZ),r.applyMatrix3(this.spaces[a].fromXYZ)),this.spaces[a].transfer===bt&&(r.r=Or(r.r),r.g=Or(r.g),r.b=Or(r.b))),r},workingToColorSpace:function(r,s){return this.convert(r,this.workingColorSpace,s)},colorSpaceToWorking:function(r,s){return this.convert(r,s,this.workingColorSpace)},getPrimaries:function(r){return this.spaces[r].primaries},getTransfer:function(r){return r===gi?Ns:this.spaces[r].transfer},getToneMappingMode:function(r){return this.spaces[r].outputColorSpaceConfig.toneMappingMode||"standard"},getLuminanceCoefficients:function(r,s=this.workingColorSpace){return r.fromArray(this.spaces[s].luminanceCoefficients)},define:function(r){Object.assign(this.spaces,r)},_getMatrix:function(r,s,a){return r.copy(this.spaces[s].toXYZ).multiply(this.spaces[a].fromXYZ)},_getDrawingBufferColorSpace:function(r){return this.spaces[r].outputColorSpaceConfig.drawingBufferColorSpace},_getUnpackColorSpace:function(r=this.workingColorSpace){return this.spaces[r].workingColorSpaceConfig.unpackColorSpace},fromWorkingColorSpace:function(r,s){return Gr("ColorManagement: .fromWorkingColorSpace() has been renamed to .workingToColorSpace()."),i.workingToColorSpace(r,s)},toWorkingColorSpace:function(r,s){return Gr("ColorManagement: .toWorkingColorSpace() has been renamed to .colorSpaceToWorking()."),i.colorSpaceToWorking(r,s)}},e=[.64,.33,.3,.6,.15,.06],t=[.2126,.7152,.0722],n=[.3127,.329];return i.define({[Gt]:{primaries:e,whitePoint:n,transfer:Ns,toXYZ:zh,fromXYZ:kh,luminanceCoefficients:t,workingColorSpaceConfig:{unpackColorSpace:ln},outputColorSpaceConfig:{drawingBufferColorSpace:ln}},[ln]:{primaries:e,whitePoint:n,transfer:bt,toXYZ:zh,fromXYZ:kh,luminanceCoefficients:t,outputColorSpaceConfig:{drawingBufferColorSpace:ln}}}),i}var dt=Am();function fi(i){return i<.04045?i*.0773993808:Math.pow(i*.9478672986+.0521327014,2.4)}function Or(i){return i<.0031308?i*12.92:1.055*Math.pow(i,.41666)-.055}var Mr,ao=class{static getDataURL(e,t="image/png"){if(/^data:/i.test(e.src)||typeof HTMLCanvasElement>"u")return e.src;let n;if(e instanceof HTMLCanvasElement)n=e;else{Mr===void 0&&(Mr=Vr("canvas")),Mr.width=e.width,Mr.height=e.height;let r=Mr.getContext("2d");e instanceof ImageData?r.putImageData(e,0,0):r.drawImage(e,0,0,e.width,e.height),n=Mr}return n.toDataURL(t)}static sRGBToLinear(e){if(typeof HTMLImageElement<"u"&&e instanceof HTMLImageElement||typeof HTMLCanvasElement<"u"&&e instanceof HTMLCanvasElement||typeof ImageBitmap<"u"&&e instanceof ImageBitmap){let t=Vr("canvas");t.width=e.width,t.height=e.height;let n=t.getContext("2d");n.drawImage(e,0,0,e.width,e.height);let r=n.getImageData(0,0,e.width,e.height),s=r.data;for(let a=0;a<s.length;a++)s[a]=fi(s[a]/255)*255;return n.putImageData(r,0,0),t}else if(e.data){let t=e.data.slice(0);for(let n=0;n<t.length;n++)t instanceof Uint8Array||t instanceof Uint8ClampedArray?t[n]=Math.floor(fi(t[n]/255)*255):t[n]=fi(t[n]);return{data:t,width:e.width,height:e.height}}else return Ze("ImageUtils.sRGBToLinear(): Unsupported image type. No color space conversion applied."),e}},Em=0,Ci=class{constructor(e=null){this.isSource=!0,Object.defineProperty(this,"id",{value:Em++}),this.uuid=la(),this.data=e,this.dataReady=!0,this.version=0}getSize(e){let t=this.data;return typeof HTMLVideoElement<"u"&&t instanceof HTMLVideoElement?e.set(t.videoWidth,t.videoHeight,0):t instanceof VideoFrame?e.set(t.displayHeight,t.displayWidth,0):t!==null?e.set(t.width,t.height,t.depth||0):e.set(0,0,0),e}set needsUpdate(e){e===!0&&this.version++}toJSON(e){let t=e===void 0||typeof e=="string";if(!t&&e.images[this.uuid]!==void 0)return e.images[this.uuid];let n={uuid:this.uuid,url:""},r=this.data;if(r!==null){let s;if(Array.isArray(r)){s=[];for(let a=0,o=r.length;a<o;a++)r[a].isDataTexture?s.push(Ol(r[a].image)):s.push(Ol(r[a]))}else s=Ol(r);n.url=s}return t||(e.images[this.uuid]=n),n}};function Ol(i){return typeof HTMLImageElement<"u"&&i instanceof HTMLImageElement||typeof HTMLCanvasElement<"u"&&i instanceof HTMLCanvasElement||typeof ImageBitmap<"u"&&i instanceof ImageBitmap?ao.getDataURL(i):i.data?{data:Array.from(i.data),width:i.width,height:i.height,type:i.data.constructor.name}:(Ze("Texture: Unable to serialize Texture."),{})}var Cm=0,zl=new k,mn=class i extends di{constructor(e=i.DEFAULT_IMAGE,t=i.DEFAULT_MAPPING,n=Lt,r=Lt,s=ft,a=mi,o=He,c=dn,u=i.DEFAULT_ANISOTROPY,f=gi){super(),this.isTexture=!0,Object.defineProperty(this,"id",{value:Cm++}),this.uuid=la(),this.name="",this.source=new Ci(e),this.mipmaps=[],this.mapping=t,this.channel=0,this.wrapS=n,this.wrapT=r,this.magFilter=s,this.minFilter=a,this.anisotropy=u,this.format=o,this.internalFormat=null,this.type=c,this.offset=new Le(0,0),this.repeat=new Le(1,1),this.center=new Le(0,0),this.rotation=0,this.matrixAutoUpdate=!0,this.matrix=new et,this.generateMipmaps=!0,this.premultiplyAlpha=!1,this.flipY=!0,this.unpackAlignment=4,this.colorSpace=f,this.userData={},this.updateRanges=[],this.version=0,this.onUpdate=null,this.renderTarget=null,this.isRenderTargetTexture=!1,this.isArrayTexture=!!(e&&e.depth&&e.depth>1),this.pmremVersion=0}get width(){return this.source.getSize(zl).x}get height(){return this.source.getSize(zl).y}get depth(){return this.source.getSize(zl).z}get image(){return this.source.data}set image(e=null){this.source.data=e}updateMatrix(){this.matrix.setUvTransform(this.offset.x,this.offset.y,this.repeat.x,this.repeat.y,this.rotation,this.center.x,this.center.y)}addUpdateRange(e,t){this.updateRanges.push({start:e,count:t})}clearUpdateRanges(){this.updateRanges.length=0}clone(){return new this.constructor().copy(this)}copy(e){return this.name=e.name,this.source=e.source,this.mipmaps=e.mipmaps.slice(0),this.mapping=e.mapping,this.channel=e.channel,this.wrapS=e.wrapS,this.wrapT=e.wrapT,this.magFilter=e.magFilter,this.minFilter=e.minFilter,this.anisotropy=e.anisotropy,this.format=e.format,this.internalFormat=e.internalFormat,this.type=e.type,this.offset.copy(e.offset),this.repeat.copy(e.repeat),this.center.copy(e.center),this.rotation=e.rotation,this.matrixAutoUpdate=e.matrixAutoUpdate,this.matrix.copy(e.matrix),this.generateMipmaps=e.generateMipmaps,this.premultiplyAlpha=e.premultiplyAlpha,this.flipY=e.flipY,this.unpackAlignment=e.unpackAlignment,this.colorSpace=e.colorSpace,this.renderTarget=e.renderTarget,this.isRenderTargetTexture=e.isRenderTargetTexture,this.isArrayTexture=e.isArrayTexture,this.userData=JSON.parse(JSON.stringify(e.userData)),this.needsUpdate=!0,this}setValues(e){for(let t in e){let n=e[t];if(n===void 0){Ze(`Texture.setValues(): parameter '${t}' has value of undefined.`);continue}let r=this[t];if(r===void 0){Ze(`Texture.setValues(): property '${t}' does not exist.`);continue}r&&n&&r.isVector2&&n.isVector2||r&&n&&r.isVector3&&n.isVector3||r&&n&&r.isMatrix3&&n.isMatrix3?r.copy(n):this[t]=n}}toJSON(e){let t=e===void 0||typeof e=="string";if(!t&&e.textures[this.uuid]!==void 0)return e.textures[this.uuid];let n={metadata:{version:4.7,type:"Texture",generator:"Texture.toJSON"},uuid:this.uuid,name:this.name,image:this.source.toJSON(e).uuid,mapping:this.mapping,channel:this.channel,repeat:[this.repeat.x,this.repeat.y],offset:[this.offset.x,this.offset.y],center:[this.center.x,this.center.y],rotation:this.rotation,wrap:[this.wrapS,this.wrapT],format:this.format,internalFormat:this.internalFormat,type:this.type,colorSpace:this.colorSpace,minFilter:this.minFilter,magFilter:this.magFilter,anisotropy:this.anisotropy,flipY:this.flipY,generateMipmaps:this.generateMipmaps,premultiplyAlpha:this.premultiplyAlpha,unpackAlignment:this.unpackAlignment};return Object.keys(this.userData).length>0&&(n.userData=this.userData),t||(e.textures[this.uuid]=n),n}dispose(){this.dispatchEvent({type:"dispose"})}transformUv(e){if(this.mapping!==bu)return e;if(e.applyMatrix3(this.matrix),e.x<0||e.x>1)switch(this.wrapS){case hn:e.x=e.x-Math.floor(e.x);break;case Lt:e.x=e.x<0?0:1;break;case ro:Math.abs(Math.floor(e.x)%2)===1?e.x=Math.ceil(e.x)-e.x:e.x=e.x-Math.floor(e.x);break}if(e.y<0||e.y>1)switch(this.wrapT){case hn:e.y=e.y-Math.floor(e.y);break;case Lt:e.y=e.y<0?0:1;break;case ro:Math.abs(Math.floor(e.y)%2)===1?e.y=Math.ceil(e.y)-e.y:e.y=e.y-Math.floor(e.y);break}return this.flipY&&(e.y=1-e.y),e}set needsUpdate(e){e===!0&&(this.version++,this.source.needsUpdate=!0)}set needsPMREMUpdate(e){e===!0&&this.pmremVersion++}};mn.DEFAULT_IMAGE=null;mn.DEFAULT_MAPPING=bu;mn.DEFAULT_ANISOTROPY=1;var ht=class i{constructor(e=0,t=0,n=0,r=1){i.prototype.isVector4=!0,this.x=e,this.y=t,this.z=n,this.w=r}get width(){return this.z}set width(e){this.z=e}get height(){return this.w}set height(e){this.w=e}set(e,t,n,r){return this.x=e,this.y=t,this.z=n,this.w=r,this}setScalar(e){return this.x=e,this.y=e,this.z=e,this.w=e,this}setX(e){return this.x=e,this}setY(e){return this.y=e,this}setZ(e){return this.z=e,this}setW(e){return this.w=e,this}setComponent(e,t){switch(e){case 0:this.x=t;break;case 1:this.y=t;break;case 2:this.z=t;break;case 3:this.w=t;break;default:throw new Error("index is out of range: "+e)}return this}getComponent(e){switch(e){case 0:return this.x;case 1:return this.y;case 2:return this.z;case 3:return this.w;default:throw new Error("index is out of range: "+e)}}clone(){return new this.constructor(this.x,this.y,this.z,this.w)}copy(e){return this.x=e.x,this.y=e.y,this.z=e.z,this.w=e.w!==void 0?e.w:1,this}add(e){return this.x+=e.x,this.y+=e.y,this.z+=e.z,this.w+=e.w,this}addScalar(e){return this.x+=e,this.y+=e,this.z+=e,this.w+=e,this}addVectors(e,t){return this.x=e.x+t.x,this.y=e.y+t.y,this.z=e.z+t.z,this.w=e.w+t.w,this}addScaledVector(e,t){return this.x+=e.x*t,this.y+=e.y*t,this.z+=e.z*t,this.w+=e.w*t,this}sub(e){return this.x-=e.x,this.y-=e.y,this.z-=e.z,this.w-=e.w,this}subScalar(e){return this.x-=e,this.y-=e,this.z-=e,this.w-=e,this}subVectors(e,t){return this.x=e.x-t.x,this.y=e.y-t.y,this.z=e.z-t.z,this.w=e.w-t.w,this}multiply(e){return this.x*=e.x,this.y*=e.y,this.z*=e.z,this.w*=e.w,this}multiplyScalar(e){return this.x*=e,this.y*=e,this.z*=e,this.w*=e,this}applyMatrix4(e){let t=this.x,n=this.y,r=this.z,s=this.w,a=e.elements;return this.x=a[0]*t+a[4]*n+a[8]*r+a[12]*s,this.y=a[1]*t+a[5]*n+a[9]*r+a[13]*s,this.z=a[2]*t+a[6]*n+a[10]*r+a[14]*s,this.w=a[3]*t+a[7]*n+a[11]*r+a[15]*s,this}divide(e){return this.x/=e.x,this.y/=e.y,this.z/=e.z,this.w/=e.w,this}divideScalar(e){return this.multiplyScalar(1/e)}setAxisAngleFromQuaternion(e){this.w=2*Math.acos(e.w);let t=Math.sqrt(1-e.w*e.w);return t<1e-4?(this.x=1,this.y=0,this.z=0):(this.x=e.x/t,this.y=e.y/t,this.z=e.z/t),this}setAxisAngleFromRotationMatrix(e){let t,n,r,s,c=e.elements,u=c[0],f=c[4],h=c[8],l=c[1],p=c[5],g=c[9],b=c[2],m=c[6],d=c[10];if(Math.abs(f-l)<.01&&Math.abs(h-b)<.01&&Math.abs(g-m)<.01){if(Math.abs(f+l)<.1&&Math.abs(h+b)<.1&&Math.abs(g+m)<.1&&Math.abs(u+p+d-3)<.1)return this.set(1,0,0,0),this;t=Math.PI;let y=(u+1)/2,M=(p+1)/2,w=(d+1)/2,A=(f+l)/4,I=(h+b)/4,D=(g+m)/4;return y>M&&y>w?y<.01?(n=0,r=.707106781,s=.707106781):(n=Math.sqrt(y),r=A/n,s=I/n):M>w?M<.01?(n=.707106781,r=0,s=.707106781):(r=Math.sqrt(M),n=A/r,s=D/r):w<.01?(n=.707106781,r=.707106781,s=0):(s=Math.sqrt(w),n=I/s,r=D/s),this.set(n,r,s,t),this}let _=Math.sqrt((m-g)*(m-g)+(h-b)*(h-b)+(l-f)*(l-f));return Math.abs(_)<.001&&(_=1),this.x=(m-g)/_,this.y=(h-b)/_,this.z=(l-f)/_,this.w=Math.acos((u+p+d-1)/2),this}setFromMatrixPosition(e){let t=e.elements;return this.x=t[12],this.y=t[13],this.z=t[14],this.w=t[15],this}min(e){return this.x=Math.min(this.x,e.x),this.y=Math.min(this.y,e.y),this.z=Math.min(this.z,e.z),this.w=Math.min(this.w,e.w),this}max(e){return this.x=Math.max(this.x,e.x),this.y=Math.max(this.y,e.y),this.z=Math.max(this.z,e.z),this.w=Math.max(this.w,e.w),this}clamp(e,t){return this.x=Ke(this.x,e.x,t.x),this.y=Ke(this.y,e.y,t.y),this.z=Ke(this.z,e.z,t.z),this.w=Ke(this.w,e.w,t.w),this}clampScalar(e,t){return this.x=Ke(this.x,e,t),this.y=Ke(this.y,e,t),this.z=Ke(this.z,e,t),this.w=Ke(this.w,e,t),this}clampLength(e,t){let n=this.length();return this.divideScalar(n||1).multiplyScalar(Ke(n,e,t))}floor(){return this.x=Math.floor(this.x),this.y=Math.floor(this.y),this.z=Math.floor(this.z),this.w=Math.floor(this.w),this}ceil(){return this.x=Math.ceil(this.x),this.y=Math.ceil(this.y),this.z=Math.ceil(this.z),this.w=Math.ceil(this.w),this}round(){return this.x=Math.round(this.x),this.y=Math.round(this.y),this.z=Math.round(this.z),this.w=Math.round(this.w),this}roundToZero(){return this.x=Math.trunc(this.x),this.y=Math.trunc(this.y),this.z=Math.trunc(this.z),this.w=Math.trunc(this.w),this}negate(){return this.x=-this.x,this.y=-this.y,this.z=-this.z,this.w=-this.w,this}dot(e){return this.x*e.x+this.y*e.y+this.z*e.z+this.w*e.w}lengthSq(){return this.x*this.x+this.y*this.y+this.z*this.z+this.w*this.w}length(){return Math.sqrt(this.x*this.x+this.y*this.y+this.z*this.z+this.w*this.w)}manhattanLength(){return Math.abs(this.x)+Math.abs(this.y)+Math.abs(this.z)+Math.abs(this.w)}normalize(){return this.divideScalar(this.length()||1)}setLength(e){return this.normalize().multiplyScalar(e)}lerp(e,t){return this.x+=(e.x-this.x)*t,this.y+=(e.y-this.y)*t,this.z+=(e.z-this.z)*t,this.w+=(e.w-this.w)*t,this}lerpVectors(e,t,n){return this.x=e.x+(t.x-e.x)*n,this.y=e.y+(t.y-e.y)*n,this.z=e.z+(t.z-e.z)*n,this.w=e.w+(t.w-e.w)*n,this}equals(e){return e.x===this.x&&e.y===this.y&&e.z===this.z&&e.w===this.w}fromArray(e,t=0){return this.x=e[t],this.y=e[t+1],this.z=e[t+2],this.w=e[t+3],this}toArray(e=[],t=0){return e[t]=this.x,e[t+1]=this.y,e[t+2]=this.z,e[t+3]=this.w,e}fromBufferAttribute(e,t){return this.x=e.getX(t),this.y=e.getY(t),this.z=e.getZ(t),this.w=e.getW(t),this}random(){return this.x=Math.random(),this.y=Math.random(),this.z=Math.random(),this.w=Math.random(),this}*[Symbol.iterator](){yield this.x,yield this.y,yield this.z,yield this.w}},oo=class extends di{constructor(e=1,t=1,n={}){super(),n=Object.assign({generateMipmaps:!1,internalFormat:null,minFilter:ft,depthBuffer:!0,stencilBuffer:!1,resolveDepthBuffer:!0,resolveStencilBuffer:!0,depthTexture:null,samples:0,count:1,depth:1,multiview:!1},n),this.isRenderTarget=!0,this.width=e,this.height=t,this.depth=n.depth,this.scissor=new ht(0,0,e,t),this.scissorTest=!1,this.viewport=new ht(0,0,e,t);let r={width:e,height:t,depth:n.depth},s=new mn(r);this.textures=[];let a=n.count;for(let o=0;o<a;o++)this.textures[o]=s.clone(),this.textures[o].isRenderTargetTexture=!0,this.textures[o].renderTarget=this;this._setTextureOptions(n),this.depthBuffer=n.depthBuffer,this.stencilBuffer=n.stencilBuffer,this.resolveDepthBuffer=n.resolveDepthBuffer,this.resolveStencilBuffer=n.resolveStencilBuffer,this._depthTexture=null,this.depthTexture=n.depthTexture,this.samples=n.samples,this.multiview=n.multiview}_setTextureOptions(e={}){let t={minFilter:ft,generateMipmaps:!1,flipY:!1,internalFormat:null};e.mapping!==void 0&&(t.mapping=e.mapping),e.wrapS!==void 0&&(t.wrapS=e.wrapS),e.wrapT!==void 0&&(t.wrapT=e.wrapT),e.wrapR!==void 0&&(t.wrapR=e.wrapR),e.magFilter!==void 0&&(t.magFilter=e.magFilter),e.minFilter!==void 0&&(t.minFilter=e.minFilter),e.format!==void 0&&(t.format=e.format),e.type!==void 0&&(t.type=e.type),e.anisotropy!==void 0&&(t.anisotropy=e.anisotropy),e.colorSpace!==void 0&&(t.colorSpace=e.colorSpace),e.flipY!==void 0&&(t.flipY=e.flipY),e.generateMipmaps!==void 0&&(t.generateMipmaps=e.generateMipmaps),e.internalFormat!==void 0&&(t.internalFormat=e.internalFormat);for(let n=0;n<this.textures.length;n++)this.textures[n].setValues(t)}get texture(){return this.textures[0]}set texture(e){this.textures[0]=e}set depthTexture(e){this._depthTexture!==null&&(this._depthTexture.renderTarget=null),e!==null&&(e.renderTarget=this),this._depthTexture=e}get depthTexture(){return this._depthTexture}setSize(e,t,n=1){if(this.width!==e||this.height!==t||this.depth!==n){this.width=e,this.height=t,this.depth=n;for(let r=0,s=this.textures.length;r<s;r++)this.textures[r].image.width=e,this.textures[r].image.height=t,this.textures[r].image.depth=n,this.textures[r].isData3DTexture!==!0&&(this.textures[r].isArrayTexture=this.textures[r].image.depth>1);this.dispose()}this.viewport.set(0,0,e,t),this.scissor.set(0,0,e,t)}clone(){return new this.constructor().copy(this)}copy(e){this.width=e.width,this.height=e.height,this.depth=e.depth,this.scissor.copy(e.scissor),this.scissorTest=e.scissorTest,this.viewport.copy(e.viewport),this.textures.length=0;for(let t=0,n=e.textures.length;t<n;t++){this.textures[t]=e.textures[t].clone(),this.textures[t].isRenderTargetTexture=!0,this.textures[t].renderTarget=this;let r=Object.assign({},e.textures[t].image);this.textures[t].source=new Ci(r)}return this.depthBuffer=e.depthBuffer,this.stencilBuffer=e.stencilBuffer,this.resolveDepthBuffer=e.resolveDepthBuffer,this.resolveStencilBuffer=e.resolveStencilBuffer,e.depthTexture!==null&&(this.depthTexture=e.depthTexture.clone()),this.samples=e.samples,this}dispose(){this.dispatchEvent({type:"dispose"})}},Yt=class extends oo{constructor(e=1,t=1,n={}){super(e,t,n),this.isWebGLRenderTarget=!0}},Ri=class extends mn{constructor(e=null,t=1,n=1,r=1){super(null),this.isDataArrayTexture=!0,this.image={data:e,width:t,height:n,depth:r},this.magFilter=je,this.minFilter=je,this.wrapR=Lt,this.generateMipmaps=!1,this.flipY=!1,this.unpackAlignment=1,this.layerUpdates=new Set}addLayerUpdate(e){this.layerUpdates.add(e)}clearLayerUpdates(){this.layerUpdates.clear()}},Os=class extends Yt{constructor(e=1,t=1,n=1,r={}){super(e,t,r),this.isWebGLArrayRenderTarget=!0,this.depth=n,this.texture=new Ri(null,e,t,n),this._setTextureOptions(r),this.texture.isRenderTargetTexture=!0}},co=class extends mn{constructor(e=null,t=1,n=1,r=1){super(null),this.isData3DTexture=!0,this.image={data:e,width:t,height:n,depth:r},this.magFilter=je,this.minFilter=je,this.wrapR=Lt,this.generateMipmaps=!1,this.flipY=!1,this.unpackAlignment=1}};var Ut=class{constructor(e=new k(1/0,1/0,1/0),t=new k(-1/0,-1/0,-1/0)){this.isBox3=!0,this.min=e,this.max=t}set(e,t){return this.min.copy(e),this.max.copy(t),this}setFromArray(e){this.makeEmpty();for(let t=0,n=e.length;t<n;t+=3)this.expandByPoint(zn.fromArray(e,t));return this}setFromBufferAttribute(e){this.makeEmpty();for(let t=0,n=e.count;t<n;t++)this.expandByPoint(zn.fromBufferAttribute(e,t));return this}setFromPoints(e){this.makeEmpty();for(let t=0,n=e.length;t<n;t++)this.expandByPoint(e[t]);return this}setFromCenterAndSize(e,t){let n=zn.copy(t).multiplyScalar(.5);return this.min.copy(e).sub(n),this.max.copy(e).add(n),this}setFromObject(e,t=!1){return this.makeEmpty(),this.expandByObject(e,t)}clone(){return new this.constructor().copy(this)}copy(e){return this.min.copy(e.min),this.max.copy(e.max),this}makeEmpty(){return this.min.x=this.min.y=this.min.z=1/0,this.max.x=this.max.y=this.max.z=-1/0,this}isEmpty(){return this.max.x<this.min.x||this.max.y<this.min.y||this.max.z<this.min.z}getCenter(e){return this.isEmpty()?e.set(0,0,0):e.addVectors(this.min,this.max).multiplyScalar(.5)}getSize(e){return this.isEmpty()?e.set(0,0,0):e.subVectors(this.max,this.min)}expandByPoint(e){return this.min.min(e),this.max.max(e),this}expandByVector(e){return this.min.sub(e),this.max.add(e),this}expandByScalar(e){return this.min.addScalar(-e),this.max.addScalar(e),this}expandByObject(e,t=!1){e.updateWorldMatrix(!1,!1);let n=e.geometry;if(n!==void 0){let s=n.getAttribute("position");if(t===!0&&s!==void 0&&e.isInstancedMesh!==!0)for(let a=0,o=s.count;a<o;a++)e.isMesh===!0?e.getVertexPosition(a,zn):zn.fromBufferAttribute(s,a),zn.applyMatrix4(e.matrixWorld),this.expandByPoint(zn);else e.boundingBox!==void 0?(e.boundingBox===null&&e.computeBoundingBox(),Ua.copy(e.boundingBox)):(n.boundingBox===null&&n.computeBoundingBox(),Ua.copy(n.boundingBox)),Ua.applyMatrix4(e.matrixWorld),this.union(Ua)}let r=e.children;for(let s=0,a=r.length;s<a;s++)this.expandByObject(r[s],t);return this}containsPoint(e){return e.x>=this.min.x&&e.x<=this.max.x&&e.y>=this.min.y&&e.y<=this.max.y&&e.z>=this.min.z&&e.z<=this.max.z}containsBox(e){return this.min.x<=e.min.x&&e.max.x<=this.max.x&&this.min.y<=e.min.y&&e.max.y<=this.max.y&&this.min.z<=e.min.z&&e.max.z<=this.max.z}getParameter(e,t){return t.set((e.x-this.min.x)/(this.max.x-this.min.x),(e.y-this.min.y)/(this.max.y-this.min.y),(e.z-this.min.z)/(this.max.z-this.min.z))}intersectsBox(e){return e.max.x>=this.min.x&&e.min.x<=this.max.x&&e.max.y>=this.min.y&&e.min.y<=this.max.y&&e.max.z>=this.min.z&&e.min.z<=this.max.z}intersectsSphere(e){return this.clampPoint(e.center,zn),zn.distanceToSquared(e.center)<=e.radius*e.radius}intersectsPlane(e){let t,n;return e.normal.x>0?(t=e.normal.x*this.min.x,n=e.normal.x*this.max.x):(t=e.normal.x*this.max.x,n=e.normal.x*this.min.x),e.normal.y>0?(t+=e.normal.y*this.min.y,n+=e.normal.y*this.max.y):(t+=e.normal.y*this.max.y,n+=e.normal.y*this.min.y),e.normal.z>0?(t+=e.normal.z*this.min.z,n+=e.normal.z*this.max.z):(t+=e.normal.z*this.max.z,n+=e.normal.z*this.min.z),t<=-e.constant&&n>=-e.constant}intersectsTriangle(e){if(this.isEmpty())return!1;this.getCenter(Rs),Ba.subVectors(this.max,Rs),Tr.subVectors(e.a,Rs),wr.subVectors(e.b,Rs),Ar.subVectors(e.c,Rs),bi.subVectors(wr,Tr),Si.subVectors(Ar,wr),Zi.subVectors(Tr,Ar);let t=[0,-bi.z,bi.y,0,-Si.z,Si.y,0,-Zi.z,Zi.y,bi.z,0,-bi.x,Si.z,0,-Si.x,Zi.z,0,-Zi.x,-bi.y,bi.x,0,-Si.y,Si.x,0,-Zi.y,Zi.x,0];return!kl(t,Tr,wr,Ar,Ba)||(t=[1,0,0,0,1,0,0,0,1],!kl(t,Tr,wr,Ar,Ba))?!1:(Oa.crossVectors(bi,Si),t=[Oa.x,Oa.y,Oa.z],kl(t,Tr,wr,Ar,Ba))}clampPoint(e,t){return t.copy(e).clamp(this.min,this.max)}distanceToPoint(e){return this.clampPoint(e,zn).distanceTo(e)}getBoundingSphere(e){return this.isEmpty()?e.makeEmpty():(this.getCenter(e.center),e.radius=this.getSize(zn).length()*.5),e}intersect(e){return this.min.max(e.min),this.max.min(e.max),this.isEmpty()&&this.makeEmpty(),this}union(e){return this.min.min(e.min),this.max.max(e.max),this}applyMatrix4(e){return this.isEmpty()?this:(si[0].set(this.min.x,this.min.y,this.min.z).applyMatrix4(e),si[1].set(this.min.x,this.min.y,this.max.z).applyMatrix4(e),si[2].set(this.min.x,this.max.y,this.min.z).applyMatrix4(e),si[3].set(this.min.x,this.max.y,this.max.z).applyMatrix4(e),si[4].set(this.max.x,this.min.y,this.min.z).applyMatrix4(e),si[5].set(this.max.x,this.min.y,this.max.z).applyMatrix4(e),si[6].set(this.max.x,this.max.y,this.min.z).applyMatrix4(e),si[7].set(this.max.x,this.max.y,this.max.z).applyMatrix4(e),this.setFromPoints(si),this)}translate(e){return this.min.add(e),this.max.add(e),this}equals(e){return e.min.equals(this.min)&&e.max.equals(this.max)}toJSON(){return{min:this.min.toArray(),max:this.max.toArray()}}fromJSON(e){return this.min.fromArray(e.min),this.max.fromArray(e.max),this}},si=[new k,new k,new k,new k,new k,new k,new k,new k],zn=new k,Ua=new Ut,Tr=new k,wr=new k,Ar=new k,bi=new k,Si=new k,Zi=new k,Rs=new k,Ba=new k,Oa=new k,$i=new k;function kl(i,e,t,n,r){for(let s=0,a=i.length-3;s<=a;s+=3){$i.fromArray(i,s);let o=r.x*Math.abs($i.x)+r.y*Math.abs($i.y)+r.z*Math.abs($i.z),c=e.dot($i),u=t.dot($i),f=n.dot($i);if(Math.max(-Math.max(c,u,f),Math.min(c,u,f))>o)return!1}return!0}var Rm=new Ut,Is=new k,Vl=new k,Wr=class{constructor(e=new k,t=-1){this.isSphere=!0,this.center=e,this.radius=t}set(e,t){return this.center.copy(e),this.radius=t,this}setFromPoints(e,t){let n=this.center;t!==void 0?n.copy(t):Rm.setFromPoints(e).getCenter(n);let r=0;for(let s=0,a=e.length;s<a;s++)r=Math.max(r,n.distanceToSquared(e[s]));return this.radius=Math.sqrt(r),this}copy(e){return this.center.copy(e.center),this.radius=e.radius,this}isEmpty(){return this.radius<0}makeEmpty(){return this.center.set(0,0,0),this.radius=-1,this}containsPoint(e){return e.distanceToSquared(this.center)<=this.radius*this.radius}distanceToPoint(e){return e.distanceTo(this.center)-this.radius}intersectsSphere(e){let t=this.radius+e.radius;return e.center.distanceToSquared(this.center)<=t*t}intersectsBox(e){return e.intersectsSphere(this)}intersectsPlane(e){return Math.abs(e.distanceToPoint(this.center))<=this.radius}clampPoint(e,t){let n=this.center.distanceToSquared(e);return t.copy(e),n>this.radius*this.radius&&(t.sub(this.center).normalize(),t.multiplyScalar(this.radius).add(this.center)),t}getBoundingBox(e){return this.isEmpty()?(e.makeEmpty(),e):(e.set(this.center,this.center),e.expandByScalar(this.radius),e)}applyMatrix4(e){return this.center.applyMatrix4(e),this.radius=this.radius*e.getMaxScaleOnAxis(),this}translate(e){return this.center.add(e),this}expandByPoint(e){if(this.isEmpty())return this.center.copy(e),this.radius=0,this;Is.subVectors(e,this.center);let t=Is.lengthSq();if(t>this.radius*this.radius){let n=Math.sqrt(t),r=(n-this.radius)*.5;this.center.addScaledVector(Is,r/n),this.radius+=r}return this}union(e){return e.isEmpty()?this:this.isEmpty()?(this.copy(e),this):(this.center.equals(e.center)===!0?this.radius=Math.max(this.radius,e.radius):(Vl.subVectors(e.center,this.center).setLength(e.radius),this.expandByPoint(Is.copy(e.center).add(Vl)),this.expandByPoint(Is.copy(e.center).sub(Vl))),this)}equals(e){return e.center.equals(this.center)&&e.radius===this.radius}clone(){return new this.constructor().copy(this)}toJSON(){return{radius:this.radius,center:this.center.toArray()}}fromJSON(e){return this.radius=e.radius,this.center.fromArray(e.center),this}},ai=new k,Hl=new k,za=new k,Mi=new k,Gl=new k,ka=new k,Wl=new k,Xr=class{constructor(e=new k,t=new k(0,0,-1)){this.origin=e,this.direction=t}set(e,t){return this.origin.copy(e),this.direction.copy(t),this}copy(e){return this.origin.copy(e.origin),this.direction.copy(e.direction),this}at(e,t){return t.copy(this.origin).addScaledVector(this.direction,e)}lookAt(e){return this.direction.copy(e).sub(this.origin).normalize(),this}recast(e){return this.origin.copy(this.at(e,ai)),this}closestPointToPoint(e,t){t.subVectors(e,this.origin);let n=t.dot(this.direction);return n<0?t.copy(this.origin):t.copy(this.origin).addScaledVector(this.direction,n)}distanceToPoint(e){return Math.sqrt(this.distanceSqToPoint(e))}distanceSqToPoint(e){let t=ai.subVectors(e,this.origin).dot(this.direction);return t<0?this.origin.distanceToSquared(e):(ai.copy(this.origin).addScaledVector(this.direction,t),ai.distanceToSquared(e))}distanceSqToSegment(e,t,n,r){Hl.copy(e).add(t).multiplyScalar(.5),za.copy(t).sub(e).normalize(),Mi.copy(this.origin).sub(Hl);let s=e.distanceTo(t)*.5,a=-this.direction.dot(za),o=Mi.dot(this.direction),c=-Mi.dot(za),u=Mi.lengthSq(),f=Math.abs(1-a*a),h,l,p,g;if(f>0)if(h=a*c-o,l=a*o-c,g=s*f,h>=0)if(l>=-g)if(l<=g){let b=1/f;h*=b,l*=b,p=h*(h+a*l+2*o)+l*(a*h+l+2*c)+u}else l=s,h=Math.max(0,-(a*l+o)),p=-h*h+l*(l+2*c)+u;else l=-s,h=Math.max(0,-(a*l+o)),p=-h*h+l*(l+2*c)+u;else l<=-g?(h=Math.max(0,-(-a*s+o)),l=h>0?-s:Math.min(Math.max(-s,-c),s),p=-h*h+l*(l+2*c)+u):l<=g?(h=0,l=Math.min(Math.max(-s,-c),s),p=l*(l+2*c)+u):(h=Math.max(0,-(a*s+o)),l=h>0?s:Math.min(Math.max(-s,-c),s),p=-h*h+l*(l+2*c)+u);else l=a>0?-s:s,h=Math.max(0,-(a*l+o)),p=-h*h+l*(l+2*c)+u;return n&&n.copy(this.origin).addScaledVector(this.direction,h),r&&r.copy(Hl).addScaledVector(za,l),p}intersectSphere(e,t){ai.subVectors(e.center,this.origin);let n=ai.dot(this.direction),r=ai.dot(ai)-n*n,s=e.radius*e.radius;if(r>s)return null;let a=Math.sqrt(s-r),o=n-a,c=n+a;return c<0?null:o<0?this.at(c,t):this.at(o,t)}intersectsSphere(e){return e.radius<0?!1:this.distanceSqToPoint(e.center)<=e.radius*e.radius}distanceToPlane(e){let t=e.normal.dot(this.direction);if(t===0)return e.distanceToPoint(this.origin)===0?0:null;let n=-(this.origin.dot(e.normal)+e.constant)/t;return n>=0?n:null}intersectPlane(e,t){let n=this.distanceToPlane(e);return n===null?null:this.at(n,t)}intersectsPlane(e){let t=e.distanceToPoint(this.origin);return t===0||e.normal.dot(this.direction)*t<0}intersectBox(e,t){let n,r,s,a,o,c,u=1/this.direction.x,f=1/this.direction.y,h=1/this.direction.z,l=this.origin;return u>=0?(n=(e.min.x-l.x)*u,r=(e.max.x-l.x)*u):(n=(e.max.x-l.x)*u,r=(e.min.x-l.x)*u),f>=0?(s=(e.min.y-l.y)*f,a=(e.max.y-l.y)*f):(s=(e.max.y-l.y)*f,a=(e.min.y-l.y)*f),n>a||s>r||((s>n||isNaN(n))&&(n=s),(a<r||isNaN(r))&&(r=a),h>=0?(o=(e.min.z-l.z)*h,c=(e.max.z-l.z)*h):(o=(e.max.z-l.z)*h,c=(e.min.z-l.z)*h),n>c||o>r)||((o>n||n!==n)&&(n=o),(c<r||r!==r)&&(r=c),r<0)?null:this.at(n>=0?n:r,t)}intersectsBox(e){return this.intersectBox(e,ai)!==null}intersectTriangle(e,t,n,r,s){Gl.subVectors(t,e),ka.subVectors(n,e),Wl.crossVectors(Gl,ka);let a=this.direction.dot(Wl),o;if(a>0){if(r)return null;o=1}else if(a<0)o=-1,a=-a;else return null;Mi.subVectors(this.origin,e);let c=o*this.direction.dot(ka.crossVectors(Mi,ka));if(c<0)return null;let u=o*this.direction.dot(Gl.cross(Mi));if(u<0||c+u>a)return null;let f=-o*Mi.dot(Wl);return f<0?null:this.at(f/a,s)}applyMatrix4(e){return this.origin.applyMatrix4(e),this.direction.transformDirection(e),this}equals(e){return e.origin.equals(this.origin)&&e.direction.equals(this.direction)}clone(){return new this.constructor().copy(this)}},Xe=class i{constructor(e,t,n,r,s,a,o,c,u,f,h,l,p,g,b,m){i.prototype.isMatrix4=!0,this.elements=[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1],e!==void 0&&this.set(e,t,n,r,s,a,o,c,u,f,h,l,p,g,b,m)}set(e,t,n,r,s,a,o,c,u,f,h,l,p,g,b,m){let d=this.elements;return d[0]=e,d[4]=t,d[8]=n,d[12]=r,d[1]=s,d[5]=a,d[9]=o,d[13]=c,d[2]=u,d[6]=f,d[10]=h,d[14]=l,d[3]=p,d[7]=g,d[11]=b,d[15]=m,this}identity(){return this.set(1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1),this}clone(){return new i().fromArray(this.elements)}copy(e){let t=this.elements,n=e.elements;return t[0]=n[0],t[1]=n[1],t[2]=n[2],t[3]=n[3],t[4]=n[4],t[5]=n[5],t[6]=n[6],t[7]=n[7],t[8]=n[8],t[9]=n[9],t[10]=n[10],t[11]=n[11],t[12]=n[12],t[13]=n[13],t[14]=n[14],t[15]=n[15],this}copyPosition(e){let t=this.elements,n=e.elements;return t[12]=n[12],t[13]=n[13],t[14]=n[14],this}setFromMatrix3(e){let t=e.elements;return this.set(t[0],t[3],t[6],0,t[1],t[4],t[7],0,t[2],t[5],t[8],0,0,0,0,1),this}extractBasis(e,t,n){return e.setFromMatrixColumn(this,0),t.setFromMatrixColumn(this,1),n.setFromMatrixColumn(this,2),this}makeBasis(e,t,n){return this.set(e.x,t.x,n.x,0,e.y,t.y,n.y,0,e.z,t.z,n.z,0,0,0,0,1),this}extractRotation(e){let t=this.elements,n=e.elements,r=1/Er.setFromMatrixColumn(e,0).length(),s=1/Er.setFromMatrixColumn(e,1).length(),a=1/Er.setFromMatrixColumn(e,2).length();return t[0]=n[0]*r,t[1]=n[1]*r,t[2]=n[2]*r,t[3]=0,t[4]=n[4]*s,t[5]=n[5]*s,t[6]=n[6]*s,t[7]=0,t[8]=n[8]*a,t[9]=n[9]*a,t[10]=n[10]*a,t[11]=0,t[12]=0,t[13]=0,t[14]=0,t[15]=1,this}makeRotationFromEuler(e){let t=this.elements,n=e.x,r=e.y,s=e.z,a=Math.cos(n),o=Math.sin(n),c=Math.cos(r),u=Math.sin(r),f=Math.cos(s),h=Math.sin(s);if(e.order==="XYZ"){let l=a*f,p=a*h,g=o*f,b=o*h;t[0]=c*f,t[4]=-c*h,t[8]=u,t[1]=p+g*u,t[5]=l-b*u,t[9]=-o*c,t[2]=b-l*u,t[6]=g+p*u,t[10]=a*c}else if(e.order==="YXZ"){let l=c*f,p=c*h,g=u*f,b=u*h;t[0]=l+b*o,t[4]=g*o-p,t[8]=a*u,t[1]=a*h,t[5]=a*f,t[9]=-o,t[2]=p*o-g,t[6]=b+l*o,t[10]=a*c}else if(e.order==="ZXY"){let l=c*f,p=c*h,g=u*f,b=u*h;t[0]=l-b*o,t[4]=-a*h,t[8]=g+p*o,t[1]=p+g*o,t[5]=a*f,t[9]=b-l*o,t[2]=-a*u,t[6]=o,t[10]=a*c}else if(e.order==="ZYX"){let l=a*f,p=a*h,g=o*f,b=o*h;t[0]=c*f,t[4]=g*u-p,t[8]=l*u+b,t[1]=c*h,t[5]=b*u+l,t[9]=p*u-g,t[2]=-u,t[6]=o*c,t[10]=a*c}else if(e.order==="YZX"){let l=a*c,p=a*u,g=o*c,b=o*u;t[0]=c*f,t[4]=b-l*h,t[8]=g*h+p,t[1]=h,t[5]=a*f,t[9]=-o*f,t[2]=-u*f,t[6]=p*h+g,t[10]=l-b*h}else if(e.order==="XZY"){let l=a*c,p=a*u,g=o*c,b=o*u;t[0]=c*f,t[4]=-h,t[8]=u*f,t[1]=l*h+b,t[5]=a*f,t[9]=p*h-g,t[2]=g*h-p,t[6]=o*f,t[10]=b*h+l}return t[3]=0,t[7]=0,t[11]=0,t[12]=0,t[13]=0,t[14]=0,t[15]=1,this}makeRotationFromQuaternion(e){return this.compose(Im,e,Pm)}lookAt(e,t,n){let r=this.elements;return En.subVectors(e,t),En.lengthSq()===0&&(En.z=1),En.normalize(),Ti.crossVectors(n,En),Ti.lengthSq()===0&&(Math.abs(n.z)===1?En.x+=1e-4:En.z+=1e-4,En.normalize(),Ti.crossVectors(n,En)),Ti.normalize(),Va.crossVectors(En,Ti),r[0]=Ti.x,r[4]=Va.x,r[8]=En.x,r[1]=Ti.y,r[5]=Va.y,r[9]=En.y,r[2]=Ti.z,r[6]=Va.z,r[10]=En.z,this}multiply(e){return this.multiplyMatrices(this,e)}premultiply(e){return this.multiplyMatrices(e,this)}multiplyMatrices(e,t){let n=e.elements,r=t.elements,s=this.elements,a=n[0],o=n[4],c=n[8],u=n[12],f=n[1],h=n[5],l=n[9],p=n[13],g=n[2],b=n[6],m=n[10],d=n[14],_=n[3],y=n[7],M=n[11],w=n[15],A=r[0],I=r[4],D=r[8],T=r[12],S=r[1],P=r[5],L=r[9],O=r[13],H=r[2],q=r[6],Y=r[10],he=r[14],j=r[3],le=r[7],ce=r[11],we=r[15];return s[0]=a*A+o*S+c*H+u*j,s[4]=a*I+o*P+c*q+u*le,s[8]=a*D+o*L+c*Y+u*ce,s[12]=a*T+o*O+c*he+u*we,s[1]=f*A+h*S+l*H+p*j,s[5]=f*I+h*P+l*q+p*le,s[9]=f*D+h*L+l*Y+p*ce,s[13]=f*T+h*O+l*he+p*we,s[2]=g*A+b*S+m*H+d*j,s[6]=g*I+b*P+m*q+d*le,s[10]=g*D+b*L+m*Y+d*ce,s[14]=g*T+b*O+m*he+d*we,s[3]=_*A+y*S+M*H+w*j,s[7]=_*I+y*P+M*q+w*le,s[11]=_*D+y*L+M*Y+w*ce,s[15]=_*T+y*O+M*he+w*we,this}multiplyScalar(e){let t=this.elements;return t[0]*=e,t[4]*=e,t[8]*=e,t[12]*=e,t[1]*=e,t[5]*=e,t[9]*=e,t[13]*=e,t[2]*=e,t[6]*=e,t[10]*=e,t[14]*=e,t[3]*=e,t[7]*=e,t[11]*=e,t[15]*=e,this}determinant(){let e=this.elements,t=e[0],n=e[4],r=e[8],s=e[12],a=e[1],o=e[5],c=e[9],u=e[13],f=e[2],h=e[6],l=e[10],p=e[14],g=e[3],b=e[7],m=e[11],d=e[15];return g*(+s*c*h-r*u*h-s*o*l+n*u*l+r*o*p-n*c*p)+b*(+t*c*p-t*u*l+s*a*l-r*a*p+r*u*f-s*c*f)+m*(+t*u*h-t*o*p-s*a*h+n*a*p+s*o*f-n*u*f)+d*(-r*o*f-t*c*h+t*o*l+r*a*h-n*a*l+n*c*f)}transpose(){let e=this.elements,t;return t=e[1],e[1]=e[4],e[4]=t,t=e[2],e[2]=e[8],e[8]=t,t=e[6],e[6]=e[9],e[9]=t,t=e[3],e[3]=e[12],e[12]=t,t=e[7],e[7]=e[13],e[13]=t,t=e[11],e[11]=e[14],e[14]=t,this}setPosition(e,t,n){let r=this.elements;return e.isVector3?(r[12]=e.x,r[13]=e.y,r[14]=e.z):(r[12]=e,r[13]=t,r[14]=n),this}invert(){let e=this.elements,t=e[0],n=e[1],r=e[2],s=e[3],a=e[4],o=e[5],c=e[6],u=e[7],f=e[8],h=e[9],l=e[10],p=e[11],g=e[12],b=e[13],m=e[14],d=e[15],_=h*m*u-b*l*u+b*c*p-o*m*p-h*c*d+o*l*d,y=g*l*u-f*m*u-g*c*p+a*m*p+f*c*d-a*l*d,M=f*b*u-g*h*u+g*o*p-a*b*p-f*o*d+a*h*d,w=g*h*c-f*b*c-g*o*l+a*b*l+f*o*m-a*h*m,A=t*_+n*y+r*M+s*w;if(A===0)return this.set(0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0);let I=1/A;return e[0]=_*I,e[1]=(b*l*s-h*m*s-b*r*p+n*m*p+h*r*d-n*l*d)*I,e[2]=(o*m*s-b*c*s+b*r*u-n*m*u-o*r*d+n*c*d)*I,e[3]=(h*c*s-o*l*s-h*r*u+n*l*u+o*r*p-n*c*p)*I,e[4]=y*I,e[5]=(f*m*s-g*l*s+g*r*p-t*m*p-f*r*d+t*l*d)*I,e[6]=(g*c*s-a*m*s-g*r*u+t*m*u+a*r*d-t*c*d)*I,e[7]=(a*l*s-f*c*s+f*r*u-t*l*u-a*r*p+t*c*p)*I,e[8]=M*I,e[9]=(g*h*s-f*b*s-g*n*p+t*b*p+f*n*d-t*h*d)*I,e[10]=(a*b*s-g*o*s+g*n*u-t*b*u-a*n*d+t*o*d)*I,e[11]=(f*o*s-a*h*s-f*n*u+t*h*u+a*n*p-t*o*p)*I,e[12]=w*I,e[13]=(f*b*r-g*h*r+g*n*l-t*b*l-f*n*m+t*h*m)*I,e[14]=(g*o*r-a*b*r-g*n*c+t*b*c+a*n*m-t*o*m)*I,e[15]=(a*h*r-f*o*r+f*n*c-t*h*c-a*n*l+t*o*l)*I,this}scale(e){let t=this.elements,n=e.x,r=e.y,s=e.z;return t[0]*=n,t[4]*=r,t[8]*=s,t[1]*=n,t[5]*=r,t[9]*=s,t[2]*=n,t[6]*=r,t[10]*=s,t[3]*=n,t[7]*=r,t[11]*=s,this}getMaxScaleOnAxis(){let e=this.elements,t=e[0]*e[0]+e[1]*e[1]+e[2]*e[2],n=e[4]*e[4]+e[5]*e[5]+e[6]*e[6],r=e[8]*e[8]+e[9]*e[9]+e[10]*e[10];return Math.sqrt(Math.max(t,n,r))}makeTranslation(e,t,n){return e.isVector3?this.set(1,0,0,e.x,0,1,0,e.y,0,0,1,e.z,0,0,0,1):this.set(1,0,0,e,0,1,0,t,0,0,1,n,0,0,0,1),this}makeRotationX(e){let t=Math.cos(e),n=Math.sin(e);return this.set(1,0,0,0,0,t,-n,0,0,n,t,0,0,0,0,1),this}makeRotationY(e){let t=Math.cos(e),n=Math.sin(e);return this.set(t,0,n,0,0,1,0,0,-n,0,t,0,0,0,0,1),this}makeRotationZ(e){let t=Math.cos(e),n=Math.sin(e);return this.set(t,-n,0,0,n,t,0,0,0,0,1,0,0,0,0,1),this}makeRotationAxis(e,t){let n=Math.cos(t),r=Math.sin(t),s=1-n,a=e.x,o=e.y,c=e.z,u=s*a,f=s*o;return this.set(u*a+n,u*o-r*c,u*c+r*o,0,u*o+r*c,f*o+n,f*c-r*a,0,u*c-r*o,f*c+r*a,s*c*c+n,0,0,0,0,1),this}makeScale(e,t,n){return this.set(e,0,0,0,0,t,0,0,0,0,n,0,0,0,0,1),this}makeShear(e,t,n,r,s,a){return this.set(1,n,s,0,e,1,a,0,t,r,1,0,0,0,0,1),this}compose(e,t,n){let r=this.elements,s=t._x,a=t._y,o=t._z,c=t._w,u=s+s,f=a+a,h=o+o,l=s*u,p=s*f,g=s*h,b=a*f,m=a*h,d=o*h,_=c*u,y=c*f,M=c*h,w=n.x,A=n.y,I=n.z;return r[0]=(1-(b+d))*w,r[1]=(p+M)*w,r[2]=(g-y)*w,r[3]=0,r[4]=(p-M)*A,r[5]=(1-(l+d))*A,r[6]=(m+_)*A,r[7]=0,r[8]=(g+y)*I,r[9]=(m-_)*I,r[10]=(1-(l+b))*I,r[11]=0,r[12]=e.x,r[13]=e.y,r[14]=e.z,r[15]=1,this}decompose(e,t,n){let r=this.elements,s=Er.set(r[0],r[1],r[2]).length(),a=Er.set(r[4],r[5],r[6]).length(),o=Er.set(r[8],r[9],r[10]).length();this.determinant()<0&&(s=-s),e.x=r[12],e.y=r[13],e.z=r[14],kn.copy(this);let u=1/s,f=1/a,h=1/o;return kn.elements[0]*=u,kn.elements[1]*=u,kn.elements[2]*=u,kn.elements[4]*=f,kn.elements[5]*=f,kn.elements[6]*=f,kn.elements[8]*=h,kn.elements[9]*=h,kn.elements[10]*=h,t.setFromRotationMatrix(kn),n.x=s,n.y=a,n.z=o,this}makePerspective(e,t,n,r,s,a,o=Hn,c=!1){let u=this.elements,f=2*s/(t-e),h=2*s/(n-r),l=(t+e)/(t-e),p=(n+r)/(n-r),g,b;if(c)g=s/(a-s),b=a*s/(a-s);else if(o===Hn)g=-(a+s)/(a-s),b=-2*a*s/(a-s);else if(o===Us)g=-a/(a-s),b=-a*s/(a-s);else throw new Error("THREE.Matrix4.makePerspective(): Invalid coordinate system: "+o);return u[0]=f,u[4]=0,u[8]=l,u[12]=0,u[1]=0,u[5]=h,u[9]=p,u[13]=0,u[2]=0,u[6]=0,u[10]=g,u[14]=b,u[3]=0,u[7]=0,u[11]=-1,u[15]=0,this}makeOrthographic(e,t,n,r,s,a,o=Hn,c=!1){let u=this.elements,f=2/(t-e),h=2/(n-r),l=-(t+e)/(t-e),p=-(n+r)/(n-r),g,b;if(c)g=1/(a-s),b=a/(a-s);else if(o===Hn)g=-2/(a-s),b=-(a+s)/(a-s);else if(o===Us)g=-1/(a-s),b=-s/(a-s);else throw new Error("THREE.Matrix4.makeOrthographic(): Invalid coordinate system: "+o);return u[0]=f,u[4]=0,u[8]=0,u[12]=l,u[1]=0,u[5]=h,u[9]=0,u[13]=p,u[2]=0,u[6]=0,u[10]=g,u[14]=b,u[3]=0,u[7]=0,u[11]=0,u[15]=1,this}equals(e){let t=this.elements,n=e.elements;for(let r=0;r<16;r++)if(t[r]!==n[r])return!1;return!0}fromArray(e,t=0){for(let n=0;n<16;n++)this.elements[n]=e[n+t];return this}toArray(e=[],t=0){let n=this.elements;return e[t]=n[0],e[t+1]=n[1],e[t+2]=n[2],e[t+3]=n[3],e[t+4]=n[4],e[t+5]=n[5],e[t+6]=n[6],e[t+7]=n[7],e[t+8]=n[8],e[t+9]=n[9],e[t+10]=n[10],e[t+11]=n[11],e[t+12]=n[12],e[t+13]=n[13],e[t+14]=n[14],e[t+15]=n[15],e}},Er=new k,kn=new Xe,Im=new k(0,0,0),Pm=new k(1,1,1),Ti=new k,Va=new k,En=new k,Vh=new Xe,Hh=new Wn,Xn=class i{constructor(e=0,t=0,n=0,r=i.DEFAULT_ORDER){this.isEuler=!0,this._x=e,this._y=t,this._z=n,this._order=r}get x(){return this._x}set x(e){this._x=e,this._onChangeCallback()}get y(){return this._y}set y(e){this._y=e,this._onChangeCallback()}get z(){return this._z}set z(e){this._z=e,this._onChangeCallback()}get order(){return this._order}set order(e){this._order=e,this._onChangeCallback()}set(e,t,n,r=this._order){return this._x=e,this._y=t,this._z=n,this._order=r,this._onChangeCallback(),this}clone(){return new this.constructor(this._x,this._y,this._z,this._order)}copy(e){return this._x=e._x,this._y=e._y,this._z=e._z,this._order=e._order,this._onChangeCallback(),this}setFromRotationMatrix(e,t=this._order,n=!0){let r=e.elements,s=r[0],a=r[4],o=r[8],c=r[1],u=r[5],f=r[9],h=r[2],l=r[6],p=r[10];switch(t){case"XYZ":this._y=Math.asin(Ke(o,-1,1)),Math.abs(o)<.9999999?(this._x=Math.atan2(-f,p),this._z=Math.atan2(-a,s)):(this._x=Math.atan2(l,u),this._z=0);break;case"YXZ":this._x=Math.asin(-Ke(f,-1,1)),Math.abs(f)<.9999999?(this._y=Math.atan2(o,p),this._z=Math.atan2(c,u)):(this._y=Math.atan2(-h,s),this._z=0);break;case"ZXY":this._x=Math.asin(Ke(l,-1,1)),Math.abs(l)<.9999999?(this._y=Math.atan2(-h,p),this._z=Math.atan2(-a,u)):(this._y=0,this._z=Math.atan2(c,s));break;case"ZYX":this._y=Math.asin(-Ke(h,-1,1)),Math.abs(h)<.9999999?(this._x=Math.atan2(l,p),this._z=Math.atan2(c,s)):(this._x=0,this._z=Math.atan2(-a,u));break;case"YZX":this._z=Math.asin(Ke(c,-1,1)),Math.abs(c)<.9999999?(this._x=Math.atan2(-f,u),this._y=Math.atan2(-h,s)):(this._x=0,this._y=Math.atan2(o,p));break;case"XZY":this._z=Math.asin(-Ke(a,-1,1)),Math.abs(a)<.9999999?(this._x=Math.atan2(l,u),this._y=Math.atan2(o,s)):(this._x=Math.atan2(-f,p),this._y=0);break;default:Ze("Euler: .setFromRotationMatrix() encountered an unknown order: "+t)}return this._order=t,n===!0&&this._onChangeCallback(),this}setFromQuaternion(e,t,n){return Vh.makeRotationFromQuaternion(e),this.setFromRotationMatrix(Vh,t,n)}setFromVector3(e,t=this._order){return this.set(e.x,e.y,e.z,t)}reorder(e){return Hh.setFromEuler(this),this.setFromQuaternion(Hh,e)}equals(e){return e._x===this._x&&e._y===this._y&&e._z===this._z&&e._order===this._order}fromArray(e){return this._x=e[0],this._y=e[1],this._z=e[2],e[3]!==void 0&&(this._order=e[3]),this._onChangeCallback(),this}toArray(e=[],t=0){return e[t]=this._x,e[t+1]=this._y,e[t+2]=this._z,e[t+3]=this._order,e}_onChange(e){return this._onChangeCallback=e,this}_onChangeCallback(){}*[Symbol.iterator](){yield this._x,yield this._y,yield this._z,yield this._order}};Xn.DEFAULT_ORDER="XYZ";var zs=class{constructor(){this.mask=1}set(e){this.mask=(1<<e|0)>>>0}enable(e){this.mask|=1<<e|0}enableAll(){this.mask=-1}toggle(e){this.mask^=1<<e|0}disable(e){this.mask&=~(1<<e|0)}disableAll(){this.mask=0}test(e){return(this.mask&e.mask)!==0}isEnabled(e){return(this.mask&(1<<e|0))!==0}},Dm=0,Gh=new k,Cr=new Wn,oi=new Xe,Ha=new k,Ps=new k,Fm=new k,Lm=new Wn,Wh=new k(1,0,0),Xh=new k(0,1,0),qh=new k(0,0,1),Yh={type:"added"},Nm={type:"removed"},Rr={type:"childadded",child:null},Xl={type:"childremoved",child:null},nn=class i extends di{constructor(){super(),this.isObject3D=!0,Object.defineProperty(this,"id",{value:Dm++}),this.uuid=la(),this.name="",this.type="Object3D",this.parent=null,this.children=[],this.up=i.DEFAULT_UP.clone();let e=new k,t=new Xn,n=new Wn,r=new k(1,1,1);function s(){n.setFromEuler(t,!1)}function a(){t.setFromQuaternion(n,void 0,!1)}t._onChange(s),n._onChange(a),Object.defineProperties(this,{position:{configurable:!0,enumerable:!0,value:e},rotation:{configurable:!0,enumerable:!0,value:t},quaternion:{configurable:!0,enumerable:!0,value:n},scale:{configurable:!0,enumerable:!0,value:r},modelViewMatrix:{value:new Xe},normalMatrix:{value:new et}}),this.matrix=new Xe,this.matrixWorld=new Xe,this.matrixAutoUpdate=i.DEFAULT_MATRIX_AUTO_UPDATE,this.matrixWorldAutoUpdate=i.DEFAULT_MATRIX_WORLD_AUTO_UPDATE,this.matrixWorldNeedsUpdate=!1,this.layers=new zs,this.visible=!0,this.castShadow=!1,this.receiveShadow=!1,this.frustumCulled=!0,this.renderOrder=0,this.animations=[],this.customDepthMaterial=void 0,this.customDistanceMaterial=void 0,this.userData={}}onBeforeShadow(){}onAfterShadow(){}onBeforeRender(){}onAfterRender(){}applyMatrix4(e){this.matrixAutoUpdate&&this.updateMatrix(),this.matrix.premultiply(e),this.matrix.decompose(this.position,this.quaternion,this.scale)}applyQuaternion(e){return this.quaternion.premultiply(e),this}setRotationFromAxisAngle(e,t){this.quaternion.setFromAxisAngle(e,t)}setRotationFromEuler(e){this.quaternion.setFromEuler(e,!0)}setRotationFromMatrix(e){this.quaternion.setFromRotationMatrix(e)}setRotationFromQuaternion(e){this.quaternion.copy(e)}rotateOnAxis(e,t){return Cr.setFromAxisAngle(e,t),this.quaternion.multiply(Cr),this}rotateOnWorldAxis(e,t){return Cr.setFromAxisAngle(e,t),this.quaternion.premultiply(Cr),this}rotateX(e){return this.rotateOnAxis(Wh,e)}rotateY(e){return this.rotateOnAxis(Xh,e)}rotateZ(e){return this.rotateOnAxis(qh,e)}translateOnAxis(e,t){return Gh.copy(e).applyQuaternion(this.quaternion),this.position.add(Gh.multiplyScalar(t)),this}translateX(e){return this.translateOnAxis(Wh,e)}translateY(e){return this.translateOnAxis(Xh,e)}translateZ(e){return this.translateOnAxis(qh,e)}localToWorld(e){return this.updateWorldMatrix(!0,!1),e.applyMatrix4(this.matrixWorld)}worldToLocal(e){return this.updateWorldMatrix(!0,!1),e.applyMatrix4(oi.copy(this.matrixWorld).invert())}lookAt(e,t,n){e.isVector3?Ha.copy(e):Ha.set(e,t,n);let r=this.parent;this.updateWorldMatrix(!0,!1),Ps.setFromMatrixPosition(this.matrixWorld),this.isCamera||this.isLight?oi.lookAt(Ps,Ha,this.up):oi.lookAt(Ha,Ps,this.up),this.quaternion.setFromRotationMatrix(oi),r&&(oi.extractRotation(r.matrixWorld),Cr.setFromRotationMatrix(oi),this.quaternion.premultiply(Cr.invert()))}add(e){if(arguments.length>1){for(let t=0;t<arguments.length;t++)this.add(arguments[t]);return this}return e===this?(ut("Object3D.add: object can't be added as a child of itself.",e),this):(e&&e.isObject3D?(e.removeFromParent(),e.parent=this,this.children.push(e),e.dispatchEvent(Yh),Rr.child=e,this.dispatchEvent(Rr),Rr.child=null):ut("Object3D.add: object not an instance of THREE.Object3D.",e),this)}remove(e){if(arguments.length>1){for(let n=0;n<arguments.length;n++)this.remove(arguments[n]);return this}let t=this.children.indexOf(e);return t!==-1&&(e.parent=null,this.children.splice(t,1),e.dispatchEvent(Nm),Xl.child=e,this.dispatchEvent(Xl),Xl.child=null),this}removeFromParent(){let e=this.parent;return e!==null&&e.remove(this),this}clear(){return this.remove(...this.children)}attach(e){return this.updateWorldMatrix(!0,!1),oi.copy(this.matrixWorld).invert(),e.parent!==null&&(e.parent.updateWorldMatrix(!0,!1),oi.multiply(e.parent.matrixWorld)),e.applyMatrix4(oi),e.removeFromParent(),e.parent=this,this.children.push(e),e.updateWorldMatrix(!1,!0),e.dispatchEvent(Yh),Rr.child=e,this.dispatchEvent(Rr),Rr.child=null,this}getObjectById(e){return this.getObjectByProperty("id",e)}getObjectByName(e){return this.getObjectByProperty("name",e)}getObjectByProperty(e,t){if(this[e]===t)return this;for(let n=0,r=this.children.length;n<r;n++){let a=this.children[n].getObjectByProperty(e,t);if(a!==void 0)return a}}getObjectsByProperty(e,t,n=[]){this[e]===t&&n.push(this);let r=this.children;for(let s=0,a=r.length;s<a;s++)r[s].getObjectsByProperty(e,t,n);return n}getWorldPosition(e){return this.updateWorldMatrix(!0,!1),e.setFromMatrixPosition(this.matrixWorld)}getWorldQuaternion(e){return this.updateWorldMatrix(!0,!1),this.matrixWorld.decompose(Ps,e,Fm),e}getWorldScale(e){return this.updateWorldMatrix(!0,!1),this.matrixWorld.decompose(Ps,Lm,e),e}getWorldDirection(e){this.updateWorldMatrix(!0,!1);let t=this.matrixWorld.elements;return e.set(t[8],t[9],t[10]).normalize()}raycast(){}traverse(e){e(this);let t=this.children;for(let n=0,r=t.length;n<r;n++)t[n].traverse(e)}traverseVisible(e){if(this.visible===!1)return;e(this);let t=this.children;for(let n=0,r=t.length;n<r;n++)t[n].traverseVisible(e)}traverseAncestors(e){let t=this.parent;t!==null&&(e(t),t.traverseAncestors(e))}updateMatrix(){this.matrix.compose(this.position,this.quaternion,this.scale),this.matrixWorldNeedsUpdate=!0}updateMatrixWorld(e){this.matrixAutoUpdate&&this.updateMatrix(),(this.matrixWorldNeedsUpdate||e)&&(this.matrixWorldAutoUpdate===!0&&(this.parent===null?this.matrixWorld.copy(this.matrix):this.matrixWorld.multiplyMatrices(this.parent.matrixWorld,this.matrix)),this.matrixWorldNeedsUpdate=!1,e=!0);let t=this.children;for(let n=0,r=t.length;n<r;n++)t[n].updateMatrixWorld(e)}updateWorldMatrix(e,t){let n=this.parent;if(e===!0&&n!==null&&n.updateWorldMatrix(!0,!1),this.matrixAutoUpdate&&this.updateMatrix(),this.matrixWorldAutoUpdate===!0&&(this.parent===null?this.matrixWorld.copy(this.matrix):this.matrixWorld.multiplyMatrices(this.parent.matrixWorld,this.matrix)),t===!0){let r=this.children;for(let s=0,a=r.length;s<a;s++)r[s].updateWorldMatrix(!1,!0)}}toJSON(e){let t=e===void 0||typeof e=="string",n={};t&&(e={geometries:{},materials:{},textures:{},images:{},shapes:{},skeletons:{},animations:{},nodes:{}},n.metadata={version:4.7,type:"Object",generator:"Object3D.toJSON"});let r={};r.uuid=this.uuid,r.type=this.type,this.name!==""&&(r.name=this.name),this.castShadow===!0&&(r.castShadow=!0),this.receiveShadow===!0&&(r.receiveShadow=!0),this.visible===!1&&(r.visible=!1),this.frustumCulled===!1&&(r.frustumCulled=!1),this.renderOrder!==0&&(r.renderOrder=this.renderOrder),Object.keys(this.userData).length>0&&(r.userData=this.userData),r.layers=this.layers.mask,r.matrix=this.matrix.toArray(),r.up=this.up.toArray(),this.matrixAutoUpdate===!1&&(r.matrixAutoUpdate=!1),this.isInstancedMesh&&(r.type="InstancedMesh",r.count=this.count,r.instanceMatrix=this.instanceMatrix.toJSON(),this.instanceColor!==null&&(r.instanceColor=this.instanceColor.toJSON())),this.isBatchedMesh&&(r.type="BatchedMesh",r.perObjectFrustumCulled=this.perObjectFrustumCulled,r.sortObjects=this.sortObjects,r.drawRanges=this._drawRanges,r.reservedRanges=this._reservedRanges,r.geometryInfo=this._geometryInfo.map(o=>({...o,boundingBox:o.boundingBox?o.boundingBox.toJSON():void 0,boundingSphere:o.boundingSphere?o.boundingSphere.toJSON():void 0})),r.instanceInfo=this._instanceInfo.map(o=>({...o})),r.availableInstanceIds=this._availableInstanceIds.slice(),r.availableGeometryIds=this._availableGeometryIds.slice(),r.nextIndexStart=this._nextIndexStart,r.nextVertexStart=this._nextVertexStart,r.geometryCount=this._geometryCount,r.maxInstanceCount=this._maxInstanceCount,r.maxVertexCount=this._maxVertexCount,r.maxIndexCount=this._maxIndexCount,r.geometryInitialized=this._geometryInitialized,r.matricesTexture=this._matricesTexture.toJSON(e),r.indirectTexture=this._indirectTexture.toJSON(e),this._colorsTexture!==null&&(r.colorsTexture=this._colorsTexture.toJSON(e)),this.boundingSphere!==null&&(r.boundingSphere=this.boundingSphere.toJSON()),this.boundingBox!==null&&(r.boundingBox=this.boundingBox.toJSON()));function s(o,c){return o[c.uuid]===void 0&&(o[c.uuid]=c.toJSON(e)),c.uuid}if(this.isScene)this.background&&(this.background.isColor?r.background=this.background.toJSON():this.background.isTexture&&(r.background=this.background.toJSON(e).uuid)),this.environment&&this.environment.isTexture&&this.environment.isRenderTargetTexture!==!0&&(r.environment=this.environment.toJSON(e).uuid);else if(this.isMesh||this.isLine||this.isPoints){r.geometry=s(e.geometries,this.geometry);let o=this.geometry.parameters;if(o!==void 0&&o.shapes!==void 0){let c=o.shapes;if(Array.isArray(c))for(let u=0,f=c.length;u<f;u++){let h=c[u];s(e.shapes,h)}else s(e.shapes,c)}}if(this.isSkinnedMesh&&(r.bindMode=this.bindMode,r.bindMatrix=this.bindMatrix.toArray(),this.skeleton!==void 0&&(s(e.skeletons,this.skeleton),r.skeleton=this.skeleton.uuid)),this.material!==void 0)if(Array.isArray(this.material)){let o=[];for(let c=0,u=this.material.length;c<u;c++)o.push(s(e.materials,this.material[c]));r.material=o}else r.material=s(e.materials,this.material);if(this.children.length>0){r.children=[];for(let o=0;o<this.children.length;o++)r.children.push(this.children[o].toJSON(e).object)}if(this.animations.length>0){r.animations=[];for(let o=0;o<this.animations.length;o++){let c=this.animations[o];r.animations.push(s(e.animations,c))}}if(t){let o=a(e.geometries),c=a(e.materials),u=a(e.textures),f=a(e.images),h=a(e.shapes),l=a(e.skeletons),p=a(e.animations),g=a(e.nodes);o.length>0&&(n.geometries=o),c.length>0&&(n.materials=c),u.length>0&&(n.textures=u),f.length>0&&(n.images=f),h.length>0&&(n.shapes=h),l.length>0&&(n.skeletons=l),p.length>0&&(n.animations=p),g.length>0&&(n.nodes=g)}return n.object=r,n;function a(o){let c=[];for(let u in o){let f=o[u];delete f.metadata,c.push(f)}return c}}clone(e){return new this.constructor().copy(this,e)}copy(e,t=!0){if(this.name=e.name,this.up.copy(e.up),this.position.copy(e.position),this.rotation.order=e.rotation.order,this.quaternion.copy(e.quaternion),this.scale.copy(e.scale),this.matrix.copy(e.matrix),this.matrixWorld.copy(e.matrixWorld),this.matrixAutoUpdate=e.matrixAutoUpdate,this.matrixWorldAutoUpdate=e.matrixWorldAutoUpdate,this.matrixWorldNeedsUpdate=e.matrixWorldNeedsUpdate,this.layers.mask=e.layers.mask,this.visible=e.visible,this.castShadow=e.castShadow,this.receiveShadow=e.receiveShadow,this.frustumCulled=e.frustumCulled,this.renderOrder=e.renderOrder,this.animations=e.animations.slice(),this.userData=JSON.parse(JSON.stringify(e.userData)),t===!0)for(let n=0;n<e.children.length;n++){let r=e.children[n];this.add(r.clone())}return this}};nn.DEFAULT_UP=new k(0,1,0);nn.DEFAULT_MATRIX_AUTO_UPDATE=!0;nn.DEFAULT_MATRIX_WORLD_AUTO_UPDATE=!0;var Vn=new k,ci=new k,ql=new k,li=new k,Ir=new k,Pr=new k,Zh=new k,Yl=new k,Zl=new k,$l=new k,Jl=new ht,Kl=new ht,Ql=new ht,un=class i{constructor(e=new k,t=new k,n=new k){this.a=e,this.b=t,this.c=n}static getNormal(e,t,n,r){r.subVectors(n,t),Vn.subVectors(e,t),r.cross(Vn);let s=r.lengthSq();return s>0?r.multiplyScalar(1/Math.sqrt(s)):r.set(0,0,0)}static getBarycoord(e,t,n,r,s){Vn.subVectors(r,t),ci.subVectors(n,t),ql.subVectors(e,t);let a=Vn.dot(Vn),o=Vn.dot(ci),c=Vn.dot(ql),u=ci.dot(ci),f=ci.dot(ql),h=a*u-o*o;if(h===0)return s.set(0,0,0),null;let l=1/h,p=(u*c-o*f)*l,g=(a*f-o*c)*l;return s.set(1-p-g,g,p)}static containsPoint(e,t,n,r){return this.getBarycoord(e,t,n,r,li)===null?!1:li.x>=0&&li.y>=0&&li.x+li.y<=1}static getInterpolation(e,t,n,r,s,a,o,c){return this.getBarycoord(e,t,n,r,li)===null?(c.x=0,c.y=0,"z"in c&&(c.z=0),"w"in c&&(c.w=0),null):(c.setScalar(0),c.addScaledVector(s,li.x),c.addScaledVector(a,li.y),c.addScaledVector(o,li.z),c)}static getInterpolatedAttribute(e,t,n,r,s,a){return Jl.setScalar(0),Kl.setScalar(0),Ql.setScalar(0),Jl.fromBufferAttribute(e,t),Kl.fromBufferAttribute(e,n),Ql.fromBufferAttribute(e,r),a.setScalar(0),a.addScaledVector(Jl,s.x),a.addScaledVector(Kl,s.y),a.addScaledVector(Ql,s.z),a}static isFrontFacing(e,t,n,r){return Vn.subVectors(n,t),ci.subVectors(e,t),Vn.cross(ci).dot(r)<0}set(e,t,n){return this.a.copy(e),this.b.copy(t),this.c.copy(n),this}setFromPointsAndIndices(e,t,n,r){return this.a.copy(e[t]),this.b.copy(e[n]),this.c.copy(e[r]),this}setFromAttributeAndIndices(e,t,n,r){return this.a.fromBufferAttribute(e,t),this.b.fromBufferAttribute(e,n),this.c.fromBufferAttribute(e,r),this}clone(){return new this.constructor().copy(this)}copy(e){return this.a.copy(e.a),this.b.copy(e.b),this.c.copy(e.c),this}getArea(){return Vn.subVectors(this.c,this.b),ci.subVectors(this.a,this.b),Vn.cross(ci).length()*.5}getMidpoint(e){return e.addVectors(this.a,this.b).add(this.c).multiplyScalar(1/3)}getNormal(e){return i.getNormal(this.a,this.b,this.c,e)}getPlane(e){return e.setFromCoplanarPoints(this.a,this.b,this.c)}getBarycoord(e,t){return i.getBarycoord(e,this.a,this.b,this.c,t)}getInterpolation(e,t,n,r,s){return i.getInterpolation(e,this.a,this.b,this.c,t,n,r,s)}containsPoint(e){return i.containsPoint(e,this.a,this.b,this.c)}isFrontFacing(e){return i.isFrontFacing(this.a,this.b,this.c,e)}intersectsBox(e){return e.intersectsTriangle(this)}closestPointToPoint(e,t){let n=this.a,r=this.b,s=this.c,a,o;Ir.subVectors(r,n),Pr.subVectors(s,n),Yl.subVectors(e,n);let c=Ir.dot(Yl),u=Pr.dot(Yl);if(c<=0&&u<=0)return t.copy(n);Zl.subVectors(e,r);let f=Ir.dot(Zl),h=Pr.dot(Zl);if(f>=0&&h<=f)return t.copy(r);let l=c*h-f*u;if(l<=0&&c>=0&&f<=0)return a=c/(c-f),t.copy(n).addScaledVector(Ir,a);$l.subVectors(e,s);let p=Ir.dot($l),g=Pr.dot($l);if(g>=0&&p<=g)return t.copy(s);let b=p*u-c*g;if(b<=0&&u>=0&&g<=0)return o=u/(u-g),t.copy(n).addScaledVector(Pr,o);let m=f*g-p*h;if(m<=0&&h-f>=0&&p-g>=0)return Zh.subVectors(s,r),o=(h-f)/(h-f+(p-g)),t.copy(r).addScaledVector(Zh,o);let d=1/(m+b+l);return a=b*d,o=l*d,t.copy(n).addScaledVector(Ir,a).addScaledVector(Pr,o)}equals(e){return e.a.equals(this.a)&&e.b.equals(this.b)&&e.c.equals(this.c)}},Yf={aliceblue:15792383,antiquewhite:16444375,aqua:65535,aquamarine:8388564,azure:15794175,beige:16119260,bisque:16770244,black:0,blanchedalmond:16772045,blue:255,blueviolet:9055202,brown:10824234,burlywood:14596231,cadetblue:6266528,chartreuse:8388352,chocolate:13789470,coral:16744272,cornflowerblue:6591981,cornsilk:16775388,crimson:14423100,cyan:65535,darkblue:139,darkcyan:35723,darkgoldenrod:12092939,darkgray:11119017,darkgreen:25600,darkgrey:11119017,darkkhaki:12433259,darkmagenta:9109643,darkolivegreen:5597999,darkorange:16747520,darkorchid:10040012,darkred:9109504,darksalmon:15308410,darkseagreen:9419919,darkslateblue:4734347,darkslategray:3100495,darkslategrey:3100495,darkturquoise:52945,darkviolet:9699539,deeppink:16716947,deepskyblue:49151,dimgray:6908265,dimgrey:6908265,dodgerblue:2003199,firebrick:11674146,floralwhite:16775920,forestgreen:2263842,fuchsia:16711935,gainsboro:14474460,ghostwhite:16316671,gold:16766720,goldenrod:14329120,gray:8421504,green:32768,greenyellow:11403055,grey:8421504,honeydew:15794160,hotpink:16738740,indianred:13458524,indigo:4915330,ivory:16777200,khaki:15787660,lavender:15132410,lavenderblush:16773365,lawngreen:8190976,lemonchiffon:16775885,lightblue:11393254,lightcoral:15761536,lightcyan:14745599,lightgoldenrodyellow:16448210,lightgray:13882323,lightgreen:9498256,lightgrey:13882323,lightpink:16758465,lightsalmon:16752762,lightseagreen:2142890,lightskyblue:8900346,lightslategray:7833753,lightslategrey:7833753,lightsteelblue:11584734,lightyellow:16777184,lime:65280,limegreen:3329330,linen:16445670,magenta:16711935,maroon:8388608,mediumaquamarine:6737322,mediumblue:205,mediumorchid:12211667,mediumpurple:9662683,mediumseagreen:3978097,mediumslateblue:8087790,mediumspringgreen:64154,mediumturquoise:4772300,mediumvioletred:13047173,midnightblue:1644912,mintcream:16121850,mistyrose:16770273,moccasin:16770229,navajowhite:16768685,navy:128,oldlace:16643558,olive:8421376,olivedrab:7048739,orange:16753920,orangered:16729344,orchid:14315734,palegoldenrod:15657130,palegreen:10025880,paleturquoise:11529966,palevioletred:14381203,papayawhip:16773077,peachpuff:16767673,peru:13468991,pink:16761035,plum:14524637,powderblue:11591910,purple:8388736,rebeccapurple:6697881,red:16711680,rosybrown:12357519,royalblue:4286945,saddlebrown:9127187,salmon:16416882,sandybrown:16032864,seagreen:3050327,seashell:16774638,sienna:10506797,silver:12632256,skyblue:8900331,slateblue:6970061,slategray:7372944,slategrey:7372944,snow:16775930,springgreen:65407,steelblue:4620980,tan:13808780,teal:32896,thistle:14204888,tomato:16737095,turquoise:4251856,violet:15631086,wheat:16113331,white:16777215,whitesmoke:16119285,yellow:16776960,yellowgreen:10145074},wi={h:0,s:0,l:0},Ga={h:0,s:0,l:0};function jl(i,e,t){return t<0&&(t+=1),t>1&&(t-=1),t<1/6?i+(e-i)*6*t:t<1/2?e:t<2/3?i+(e-i)*6*(2/3-t):i}var Ye=class{constructor(e,t,n){return this.isColor=!0,this.r=1,this.g=1,this.b=1,this.set(e,t,n)}set(e,t,n){if(t===void 0&&n===void 0){let r=e;r&&r.isColor?this.copy(r):typeof r=="number"?this.setHex(r):typeof r=="string"&&this.setStyle(r)}else this.setRGB(e,t,n);return this}setScalar(e){return this.r=e,this.g=e,this.b=e,this}setHex(e,t=ln){return e=Math.floor(e),this.r=(e>>16&255)/255,this.g=(e>>8&255)/255,this.b=(e&255)/255,dt.colorSpaceToWorking(this,t),this}setRGB(e,t,n,r=dt.workingColorSpace){return this.r=e,this.g=t,this.b=n,dt.colorSpaceToWorking(this,r),this}setHSL(e,t,n,r=dt.workingColorSpace){if(e=wm(e,1),t=Ke(t,0,1),n=Ke(n,0,1),t===0)this.r=this.g=this.b=n;else{let s=n<=.5?n*(1+t):n+t-n*t,a=2*n-s;this.r=jl(a,s,e+1/3),this.g=jl(a,s,e),this.b=jl(a,s,e-1/3)}return dt.colorSpaceToWorking(this,r),this}setStyle(e,t=ln){function n(s){s!==void 0&&parseFloat(s)<1&&Ze("Color: Alpha component of "+e+" will be ignored.")}let r;if(r=/^(\w+)\(([^\)]*)\)/.exec(e)){let s,a=r[1],o=r[2];switch(a){case"rgb":case"rgba":if(s=/^\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*(?:,\s*(\d*\.?\d+)\s*)?$/.exec(o))return n(s[4]),this.setRGB(Math.min(255,parseInt(s[1],10))/255,Math.min(255,parseInt(s[2],10))/255,Math.min(255,parseInt(s[3],10))/255,t);if(s=/^\s*(\d+)\%\s*,\s*(\d+)\%\s*,\s*(\d+)\%\s*(?:,\s*(\d*\.?\d+)\s*)?$/.exec(o))return n(s[4]),this.setRGB(Math.min(100,parseInt(s[1],10))/100,Math.min(100,parseInt(s[2],10))/100,Math.min(100,parseInt(s[3],10))/100,t);break;case"hsl":case"hsla":if(s=/^\s*(\d*\.?\d+)\s*,\s*(\d*\.?\d+)\%\s*,\s*(\d*\.?\d+)\%\s*(?:,\s*(\d*\.?\d+)\s*)?$/.exec(o))return n(s[4]),this.setHSL(parseFloat(s[1])/360,parseFloat(s[2])/100,parseFloat(s[3])/100,t);break;default:Ze("Color: Unknown color model "+e)}}else if(r=/^\#([A-Fa-f\d]+)$/.exec(e)){let s=r[1],a=s.length;if(a===3)return this.setRGB(parseInt(s.charAt(0),16)/15,parseInt(s.charAt(1),16)/15,parseInt(s.charAt(2),16)/15,t);if(a===6)return this.setHex(parseInt(s,16),t);Ze("Color: Invalid hex color "+e)}else if(e&&e.length>0)return this.setColorName(e,t);return this}setColorName(e,t=ln){let n=Yf[e.toLowerCase()];return n!==void 0?this.setHex(n,t):Ze("Color: Unknown color "+e),this}clone(){return new this.constructor(this.r,this.g,this.b)}copy(e){return this.r=e.r,this.g=e.g,this.b=e.b,this}copySRGBToLinear(e){return this.r=fi(e.r),this.g=fi(e.g),this.b=fi(e.b),this}copyLinearToSRGB(e){return this.r=Or(e.r),this.g=Or(e.g),this.b=Or(e.b),this}convertSRGBToLinear(){return this.copySRGBToLinear(this),this}convertLinearToSRGB(){return this.copyLinearToSRGB(this),this}getHex(e=ln){return dt.workingToColorSpace(cn.copy(this),e),Math.round(Ke(cn.r*255,0,255))*65536+Math.round(Ke(cn.g*255,0,255))*256+Math.round(Ke(cn.b*255,0,255))}getHexString(e=ln){return("000000"+this.getHex(e).toString(16)).slice(-6)}getHSL(e,t=dt.workingColorSpace){dt.workingToColorSpace(cn.copy(this),t);let n=cn.r,r=cn.g,s=cn.b,a=Math.max(n,r,s),o=Math.min(n,r,s),c,u,f=(o+a)/2;if(o===a)c=0,u=0;else{let h=a-o;switch(u=f<=.5?h/(a+o):h/(2-a-o),a){case n:c=(r-s)/h+(r<s?6:0);break;case r:c=(s-n)/h+2;break;case s:c=(n-r)/h+4;break}c/=6}return e.h=c,e.s=u,e.l=f,e}getRGB(e,t=dt.workingColorSpace){return dt.workingToColorSpace(cn.copy(this),t),e.r=cn.r,e.g=cn.g,e.b=cn.b,e}getStyle(e=ln){dt.workingToColorSpace(cn.copy(this),e);let t=cn.r,n=cn.g,r=cn.b;return e!==ln?`color(${e} ${t.toFixed(3)} ${n.toFixed(3)} ${r.toFixed(3)})`:`rgb(${Math.round(t*255)},${Math.round(n*255)},${Math.round(r*255)})`}offsetHSL(e,t,n){return this.getHSL(wi),this.setHSL(wi.h+e,wi.s+t,wi.l+n)}add(e){return this.r+=e.r,this.g+=e.g,this.b+=e.b,this}addColors(e,t){return this.r=e.r+t.r,this.g=e.g+t.g,this.b=e.b+t.b,this}addScalar(e){return this.r+=e,this.g+=e,this.b+=e,this}sub(e){return this.r=Math.max(0,this.r-e.r),this.g=Math.max(0,this.g-e.g),this.b=Math.max(0,this.b-e.b),this}multiply(e){return this.r*=e.r,this.g*=e.g,this.b*=e.b,this}multiplyScalar(e){return this.r*=e,this.g*=e,this.b*=e,this}lerp(e,t){return this.r+=(e.r-this.r)*t,this.g+=(e.g-this.g)*t,this.b+=(e.b-this.b)*t,this}lerpColors(e,t,n){return this.r=e.r+(t.r-e.r)*n,this.g=e.g+(t.g-e.g)*n,this.b=e.b+(t.b-e.b)*n,this}lerpHSL(e,t){this.getHSL(wi),e.getHSL(Ga);let n=Nl(wi.h,Ga.h,t),r=Nl(wi.s,Ga.s,t),s=Nl(wi.l,Ga.l,t);return this.setHSL(n,r,s),this}setFromVector3(e){return this.r=e.x,this.g=e.y,this.b=e.z,this}applyMatrix3(e){let t=this.r,n=this.g,r=this.b,s=e.elements;return this.r=s[0]*t+s[3]*n+s[6]*r,this.g=s[1]*t+s[4]*n+s[7]*r,this.b=s[2]*t+s[5]*n+s[8]*r,this}equals(e){return e.r===this.r&&e.g===this.g&&e.b===this.b}fromArray(e,t=0){return this.r=e[t],this.g=e[t+1],this.b=e[t+2],this}toArray(e=[],t=0){return e[t]=this.r,e[t+1]=this.g,e[t+2]=this.b,e}fromBufferAttribute(e,t){return this.r=e.getX(t),this.g=e.getY(t),this.b=e.getZ(t),this}toJSON(){return this.getHex()}*[Symbol.iterator](){yield this.r,yield this.g,yield this.b}},cn=new Ye;Ye.NAMES=Yf;var Um=0,Ii=class extends di{constructor(){super(),this.isMaterial=!0,Object.defineProperty(this,"id",{value:Um++}),this.uuid=la(),this.name="",this.type="Material",this.blending=Gn,this.side=Mn,this.vertexColors=!1,this.opacity=1,this.transparent=!1,this.alphaHash=!1,this.blendSrc=no,this.blendDst=io,this.blendEquation=Ei,this.blendSrcAlpha=null,this.blendDstAlpha=null,this.blendEquationAlpha=null,this.blendColor=new Ye(0,0,0),this.blendAlpha=0,this.depthFunc=er,this.depthTest=!0,this.depthWrite=!0,this.stencilWriteMask=255,this.stencilFunc=lu,this.stencilRef=0,this.stencilFuncMask=255,this.stencilFail=Qi,this.stencilZFail=Qi,this.stencilZPass=Qi,this.stencilWrite=!1,this.clippingPlanes=null,this.clipIntersection=!1,this.clipShadows=!1,this.shadowSide=null,this.colorWrite=!0,this.precision=null,this.polygonOffset=!1,this.polygonOffsetFactor=0,this.polygonOffsetUnits=0,this.dithering=!1,this.alphaToCoverage=!1,this.premultipliedAlpha=!1,this.forceSinglePass=!1,this.allowOverride=!0,this.visible=!0,this.toneMapped=!0,this.userData={},this.version=0,this._alphaTest=0}get alphaTest(){return this._alphaTest}set alphaTest(e){this._alphaTest>0!=e>0&&this.version++,this._alphaTest=e}onBeforeRender(){}onBeforeCompile(){}customProgramCacheKey(){return this.onBeforeCompile.toString()}setValues(e){if(e!==void 0)for(let t in e){let n=e[t];if(n===void 0){Ze(`Material: parameter '${t}' has value of undefined.`);continue}let r=this[t];if(r===void 0){Ze(`Material: '${t}' is not a property of THREE.${this.type}.`);continue}r&&r.isColor?r.set(n):r&&r.isVector3&&n&&n.isVector3?r.copy(n):this[t]=n}}toJSON(e){let t=e===void 0||typeof e=="string";t&&(e={textures:{},images:{}});let n={metadata:{version:4.7,type:"Material",generator:"Material.toJSON"}};n.uuid=this.uuid,n.type=this.type,this.name!==""&&(n.name=this.name),this.color&&this.color.isColor&&(n.color=this.color.getHex()),this.roughness!==void 0&&(n.roughness=this.roughness),this.metalness!==void 0&&(n.metalness=this.metalness),this.sheen!==void 0&&(n.sheen=this.sheen),this.sheenColor&&this.sheenColor.isColor&&(n.sheenColor=this.sheenColor.getHex()),this.sheenRoughness!==void 0&&(n.sheenRoughness=this.sheenRoughness),this.emissive&&this.emissive.isColor&&(n.emissive=this.emissive.getHex()),this.emissiveIntensity!==void 0&&this.emissiveIntensity!==1&&(n.emissiveIntensity=this.emissiveIntensity),this.specular&&this.specular.isColor&&(n.specular=this.specular.getHex()),this.specularIntensity!==void 0&&(n.specularIntensity=this.specularIntensity),this.specularColor&&this.specularColor.isColor&&(n.specularColor=this.specularColor.getHex()),this.shininess!==void 0&&(n.shininess=this.shininess),this.clearcoat!==void 0&&(n.clearcoat=this.clearcoat),this.clearcoatRoughness!==void 0&&(n.clearcoatRoughness=this.clearcoatRoughness),this.clearcoatMap&&this.clearcoatMap.isTexture&&(n.clearcoatMap=this.clearcoatMap.toJSON(e).uuid),this.clearcoatRoughnessMap&&this.clearcoatRoughnessMap.isTexture&&(n.clearcoatRoughnessMap=this.clearcoatRoughnessMap.toJSON(e).uuid),this.clearcoatNormalMap&&this.clearcoatNormalMap.isTexture&&(n.clearcoatNormalMap=this.clearcoatNormalMap.toJSON(e).uuid,n.clearcoatNormalScale=this.clearcoatNormalScale.toArray()),this.sheenColorMap&&this.sheenColorMap.isTexture&&(n.sheenColorMap=this.sheenColorMap.toJSON(e).uuid),this.sheenRoughnessMap&&this.sheenRoughnessMap.isTexture&&(n.sheenRoughnessMap=this.sheenRoughnessMap.toJSON(e).uuid),this.dispersion!==void 0&&(n.dispersion=this.dispersion),this.iridescence!==void 0&&(n.iridescence=this.iridescence),this.iridescenceIOR!==void 0&&(n.iridescenceIOR=this.iridescenceIOR),this.iridescenceThicknessRange!==void 0&&(n.iridescenceThicknessRange=this.iridescenceThicknessRange),this.iridescenceMap&&this.iridescenceMap.isTexture&&(n.iridescenceMap=this.iridescenceMap.toJSON(e).uuid),this.iridescenceThicknessMap&&this.iridescenceThicknessMap.isTexture&&(n.iridescenceThicknessMap=this.iridescenceThicknessMap.toJSON(e).uuid),this.anisotropy!==void 0&&(n.anisotropy=this.anisotropy),this.anisotropyRotation!==void 0&&(n.anisotropyRotation=this.anisotropyRotation),this.anisotropyMap&&this.anisotropyMap.isTexture&&(n.anisotropyMap=this.anisotropyMap.toJSON(e).uuid),this.map&&this.map.isTexture&&(n.map=this.map.toJSON(e).uuid),this.matcap&&this.matcap.isTexture&&(n.matcap=this.matcap.toJSON(e).uuid),this.alphaMap&&this.alphaMap.isTexture&&(n.alphaMap=this.alphaMap.toJSON(e).uuid),this.lightMap&&this.lightMap.isTexture&&(n.lightMap=this.lightMap.toJSON(e).uuid,n.lightMapIntensity=this.lightMapIntensity),this.aoMap&&this.aoMap.isTexture&&(n.aoMap=this.aoMap.toJSON(e).uuid,n.aoMapIntensity=this.aoMapIntensity),this.bumpMap&&this.bumpMap.isTexture&&(n.bumpMap=this.bumpMap.toJSON(e).uuid,n.bumpScale=this.bumpScale),this.normalMap&&this.normalMap.isTexture&&(n.normalMap=this.normalMap.toJSON(e).uuid,n.normalMapType=this.normalMapType,n.normalScale=this.normalScale.toArray()),this.displacementMap&&this.displacementMap.isTexture&&(n.displacementMap=this.displacementMap.toJSON(e).uuid,n.displacementScale=this.displacementScale,n.displacementBias=this.displacementBias),this.roughnessMap&&this.roughnessMap.isTexture&&(n.roughnessMap=this.roughnessMap.toJSON(e).uuid),this.metalnessMap&&this.metalnessMap.isTexture&&(n.metalnessMap=this.metalnessMap.toJSON(e).uuid),this.emissiveMap&&this.emissiveMap.isTexture&&(n.emissiveMap=this.emissiveMap.toJSON(e).uuid),this.specularMap&&this.specularMap.isTexture&&(n.specularMap=this.specularMap.toJSON(e).uuid),this.specularIntensityMap&&this.specularIntensityMap.isTexture&&(n.specularIntensityMap=this.specularIntensityMap.toJSON(e).uuid),this.specularColorMap&&this.specularColorMap.isTexture&&(n.specularColorMap=this.specularColorMap.toJSON(e).uuid),this.envMap&&this.envMap.isTexture&&(n.envMap=this.envMap.toJSON(e).uuid,this.combine!==void 0&&(n.combine=this.combine)),this.envMapRotation!==void 0&&(n.envMapRotation=this.envMapRotation.toArray()),this.envMapIntensity!==void 0&&(n.envMapIntensity=this.envMapIntensity),this.reflectivity!==void 0&&(n.reflectivity=this.reflectivity),this.refractionRatio!==void 0&&(n.refractionRatio=this.refractionRatio),this.gradientMap&&this.gradientMap.isTexture&&(n.gradientMap=this.gradientMap.toJSON(e).uuid),this.transmission!==void 0&&(n.transmission=this.transmission),this.transmissionMap&&this.transmissionMap.isTexture&&(n.transmissionMap=this.transmissionMap.toJSON(e).uuid),this.thickness!==void 0&&(n.thickness=this.thickness),this.thicknessMap&&this.thicknessMap.isTexture&&(n.thicknessMap=this.thicknessMap.toJSON(e).uuid),this.attenuationDistance!==void 0&&this.attenuationDistance!==1/0&&(n.attenuationDistance=this.attenuationDistance),this.attenuationColor!==void 0&&(n.attenuationColor=this.attenuationColor.getHex()),this.size!==void 0&&(n.size=this.size),this.shadowSide!==null&&(n.shadowSide=this.shadowSide),this.sizeAttenuation!==void 0&&(n.sizeAttenuation=this.sizeAttenuation),this.blending!==Gn&&(n.blending=this.blending),this.side!==Mn&&(n.side=this.side),this.vertexColors===!0&&(n.vertexColors=!0),this.opacity<1&&(n.opacity=this.opacity),this.transparent===!0&&(n.transparent=!0),this.blendSrc!==no&&(n.blendSrc=this.blendSrc),this.blendDst!==io&&(n.blendDst=this.blendDst),this.blendEquation!==Ei&&(n.blendEquation=this.blendEquation),this.blendSrcAlpha!==null&&(n.blendSrcAlpha=this.blendSrcAlpha),this.blendDstAlpha!==null&&(n.blendDstAlpha=this.blendDstAlpha),this.blendEquationAlpha!==null&&(n.blendEquationAlpha=this.blendEquationAlpha),this.blendColor&&this.blendColor.isColor&&(n.blendColor=this.blendColor.getHex()),this.blendAlpha!==0&&(n.blendAlpha=this.blendAlpha),this.depthFunc!==er&&(n.depthFunc=this.depthFunc),this.depthTest===!1&&(n.depthTest=this.depthTest),this.depthWrite===!1&&(n.depthWrite=this.depthWrite),this.colorWrite===!1&&(n.colorWrite=this.colorWrite),this.stencilWriteMask!==255&&(n.stencilWriteMask=this.stencilWriteMask),this.stencilFunc!==lu&&(n.stencilFunc=this.stencilFunc),this.stencilRef!==0&&(n.stencilRef=this.stencilRef),this.stencilFuncMask!==255&&(n.stencilFuncMask=this.stencilFuncMask),this.stencilFail!==Qi&&(n.stencilFail=this.stencilFail),this.stencilZFail!==Qi&&(n.stencilZFail=this.stencilZFail),this.stencilZPass!==Qi&&(n.stencilZPass=this.stencilZPass),this.stencilWrite===!0&&(n.stencilWrite=this.stencilWrite),this.rotation!==void 0&&this.rotation!==0&&(n.rotation=this.rotation),this.polygonOffset===!0&&(n.polygonOffset=!0),this.polygonOffsetFactor!==0&&(n.polygonOffsetFactor=this.polygonOffsetFactor),this.polygonOffsetUnits!==0&&(n.polygonOffsetUnits=this.polygonOffsetUnits),this.linewidth!==void 0&&this.linewidth!==1&&(n.linewidth=this.linewidth),this.dashSize!==void 0&&(n.dashSize=this.dashSize),this.gapSize!==void 0&&(n.gapSize=this.gapSize),this.scale!==void 0&&(n.scale=this.scale),this.dithering===!0&&(n.dithering=!0),this.alphaTest>0&&(n.alphaTest=this.alphaTest),this.alphaHash===!0&&(n.alphaHash=!0),this.alphaToCoverage===!0&&(n.alphaToCoverage=!0),this.premultipliedAlpha===!0&&(n.premultipliedAlpha=!0),this.forceSinglePass===!0&&(n.forceSinglePass=!0),this.wireframe===!0&&(n.wireframe=!0),this.wireframeLinewidth>1&&(n.wireframeLinewidth=this.wireframeLinewidth),this.wireframeLinecap!=="round"&&(n.wireframeLinecap=this.wireframeLinecap),this.wireframeLinejoin!=="round"&&(n.wireframeLinejoin=this.wireframeLinejoin),this.flatShading===!0&&(n.flatShading=!0),this.visible===!1&&(n.visible=!1),this.toneMapped===!1&&(n.toneMapped=!1),this.fog===!1&&(n.fog=!1),Object.keys(this.userData).length>0&&(n.userData=this.userData);function r(s){let a=[];for(let o in s){let c=s[o];delete c.metadata,a.push(c)}return a}if(t){let s=r(e.textures),a=r(e.images);s.length>0&&(n.textures=s),a.length>0&&(n.images=a)}return n}clone(){return new this.constructor().copy(this)}copy(e){this.name=e.name,this.blending=e.blending,this.side=e.side,this.vertexColors=e.vertexColors,this.opacity=e.opacity,this.transparent=e.transparent,this.blendSrc=e.blendSrc,this.blendDst=e.blendDst,this.blendEquation=e.blendEquation,this.blendSrcAlpha=e.blendSrcAlpha,this.blendDstAlpha=e.blendDstAlpha,this.blendEquationAlpha=e.blendEquationAlpha,this.blendColor.copy(e.blendColor),this.blendAlpha=e.blendAlpha,this.depthFunc=e.depthFunc,this.depthTest=e.depthTest,this.depthWrite=e.depthWrite,this.stencilWriteMask=e.stencilWriteMask,this.stencilFunc=e.stencilFunc,this.stencilRef=e.stencilRef,this.stencilFuncMask=e.stencilFuncMask,this.stencilFail=e.stencilFail,this.stencilZFail=e.stencilZFail,this.stencilZPass=e.stencilZPass,this.stencilWrite=e.stencilWrite;let t=e.clippingPlanes,n=null;if(t!==null){let r=t.length;n=new Array(r);for(let s=0;s!==r;++s)n[s]=t[s].clone()}return this.clippingPlanes=n,this.clipIntersection=e.clipIntersection,this.clipShadows=e.clipShadows,this.shadowSide=e.shadowSide,this.colorWrite=e.colorWrite,this.precision=e.precision,this.polygonOffset=e.polygonOffset,this.polygonOffsetFactor=e.polygonOffsetFactor,this.polygonOffsetUnits=e.polygonOffsetUnits,this.dithering=e.dithering,this.alphaTest=e.alphaTest,this.alphaHash=e.alphaHash,this.alphaToCoverage=e.alphaToCoverage,this.premultipliedAlpha=e.premultipliedAlpha,this.forceSinglePass=e.forceSinglePass,this.visible=e.visible,this.toneMapped=e.toneMapped,this.userData=JSON.parse(JSON.stringify(e.userData)),this}dispose(){this.dispatchEvent({type:"dispose"})}set needsUpdate(e){e===!0&&this.version++}},tr=class extends Ii{constructor(e){super(),this.isMeshBasicMaterial=!0,this.type="MeshBasicMaterial",this.color=new Ye(16777215),this.map=null,this.lightMap=null,this.lightMapIntensity=1,this.aoMap=null,this.aoMapIntensity=1,this.specularMap=null,this.alphaMap=null,this.envMap=null,this.envMapRotation=new Xn,this.combine=yu,this.reflectivity=1,this.refractionRatio=.98,this.wireframe=!1,this.wireframeLinewidth=1,this.wireframeLinecap="round",this.wireframeLinejoin="round",this.fog=!0,this.setValues(e)}copy(e){return super.copy(e),this.color.copy(e.color),this.map=e.map,this.lightMap=e.lightMap,this.lightMapIntensity=e.lightMapIntensity,this.aoMap=e.aoMap,this.aoMapIntensity=e.aoMapIntensity,this.specularMap=e.specularMap,this.alphaMap=e.alphaMap,this.envMap=e.envMap,this.envMapRotation.copy(e.envMapRotation),this.combine=e.combine,this.reflectivity=e.reflectivity,this.refractionRatio=e.refractionRatio,this.wireframe=e.wireframe,this.wireframeLinewidth=e.wireframeLinewidth,this.wireframeLinecap=e.wireframeLinecap,this.wireframeLinejoin=e.wireframeLinejoin,this.fog=e.fog,this}},hi=Bm();function Bm(){let i=new ArrayBuffer(4),e=new Float32Array(i),t=new Uint32Array(i),n=new Uint32Array(512),r=new Uint32Array(512);for(let c=0;c<256;++c){let u=c-127;u<-27?(n[c]=0,n[c|256]=32768,r[c]=24,r[c|256]=24):u<-14?(n[c]=1024>>-u-14,n[c|256]=1024>>-u-14|32768,r[c]=-u-1,r[c|256]=-u-1):u<=15?(n[c]=u+15<<10,n[c|256]=u+15<<10|32768,r[c]=13,r[c|256]=13):u<128?(n[c]=31744,n[c|256]=64512,r[c]=24,r[c|256]=24):(n[c]=31744,n[c|256]=64512,r[c]=13,r[c|256]=13)}let s=new Uint32Array(2048),a=new Uint32Array(64),o=new Uint32Array(64);for(let c=1;c<1024;++c){let u=c<<13,f=0;for(;(u&8388608)===0;)u<<=1,f-=8388608;u&=-8388609,f+=947912704,s[c]=u|f}for(let c=1024;c<2048;++c)s[c]=939524096+(c-1024<<13);for(let c=1;c<31;++c)a[c]=c<<23;a[31]=1199570944,a[32]=2147483648;for(let c=33;c<63;++c)a[c]=2147483648+(c-32<<23);a[63]=3347054592;for(let c=1;c<64;++c)c!==32&&(o[c]=1024);return{floatView:e,uint32View:t,baseTable:n,shiftTable:r,mantissaTable:s,exponentTable:a,offsetTable:o}}function Om(i){Math.abs(i)>65504&&Ze("DataUtils.toHalfFloat(): Value out of range."),i=Ke(i,-65504,65504),hi.floatView[0]=i;let e=hi.uint32View[0],t=e>>23&511;return hi.baseTable[t]+((e&8388607)>>hi.shiftTable[t])}function zm(i){let e=i>>10;return hi.uint32View[0]=hi.mantissaTable[hi.offsetTable[e]+(i&1023)]+hi.exponentTable[e],hi.floatView[0]}var Ot=class{static toHalfFloat(e){return Om(e)}static fromHalfFloat(e){return zm(e)}},Wt=new k,Wa=new Le,km=0,mt=class{constructor(e,t,n=!1){if(Array.isArray(e))throw new TypeError("THREE.BufferAttribute: array should be a Typed Array.");this.isBufferAttribute=!0,Object.defineProperty(this,"id",{value:km++}),this.name="",this.array=e,this.itemSize=t,this.count=e!==void 0?e.length/t:0,this.normalized=n,this.usage=uu,this.updateRanges=[],this.gpuType=qe,this.version=0}onUploadCallback(){}set needsUpdate(e){e===!0&&this.version++}setUsage(e){return this.usage=e,this}addUpdateRange(e,t){this.updateRanges.push({start:e,count:t})}clearUpdateRanges(){this.updateRanges.length=0}copy(e){return this.name=e.name,this.array=new e.array.constructor(e.array),this.itemSize=e.itemSize,this.count=e.count,this.normalized=e.normalized,this.usage=e.usage,this.gpuType=e.gpuType,this}copyAt(e,t,n){e*=this.itemSize,n*=t.itemSize;for(let r=0,s=this.itemSize;r<s;r++)this.array[e+r]=t.array[n+r];return this}copyArray(e){return this.array.set(e),this}applyMatrix3(e){if(this.itemSize===2)for(let t=0,n=this.count;t<n;t++)Wa.fromBufferAttribute(this,t),Wa.applyMatrix3(e),this.setXY(t,Wa.x,Wa.y);else if(this.itemSize===3)for(let t=0,n=this.count;t<n;t++)Wt.fromBufferAttribute(this,t),Wt.applyMatrix3(e),this.setXYZ(t,Wt.x,Wt.y,Wt.z);return this}applyMatrix4(e){for(let t=0,n=this.count;t<n;t++)Wt.fromBufferAttribute(this,t),Wt.applyMatrix4(e),this.setXYZ(t,Wt.x,Wt.y,Wt.z);return this}applyNormalMatrix(e){for(let t=0,n=this.count;t<n;t++)Wt.fromBufferAttribute(this,t),Wt.applyNormalMatrix(e),this.setXYZ(t,Wt.x,Wt.y,Wt.z);return this}transformDirection(e){for(let t=0,n=this.count;t<n;t++)Wt.fromBufferAttribute(this,t),Wt.transformDirection(e),this.setXYZ(t,Wt.x,Wt.y,Wt.z);return this}set(e,t=0){return this.array.set(e,t),this}getComponent(e,t){let n=this.array[e*this.itemSize+t];return this.normalized&&(n=Cs(n,this.array)),n}setComponent(e,t,n){return this.normalized&&(n=bn(n,this.array)),this.array[e*this.itemSize+t]=n,this}getX(e){let t=this.array[e*this.itemSize];return this.normalized&&(t=Cs(t,this.array)),t}setX(e,t){return this.normalized&&(t=bn(t,this.array)),this.array[e*this.itemSize]=t,this}getY(e){let t=this.array[e*this.itemSize+1];return this.normalized&&(t=Cs(t,this.array)),t}setY(e,t){return this.normalized&&(t=bn(t,this.array)),this.array[e*this.itemSize+1]=t,this}getZ(e){let t=this.array[e*this.itemSize+2];return this.normalized&&(t=Cs(t,this.array)),t}setZ(e,t){return this.normalized&&(t=bn(t,this.array)),this.array[e*this.itemSize+2]=t,this}getW(e){let t=this.array[e*this.itemSize+3];return this.normalized&&(t=Cs(t,this.array)),t}setW(e,t){return this.normalized&&(t=bn(t,this.array)),this.array[e*this.itemSize+3]=t,this}setXY(e,t,n){return e*=this.itemSize,this.normalized&&(t=bn(t,this.array),n=bn(n,this.array)),this.array[e+0]=t,this.array[e+1]=n,this}setXYZ(e,t,n,r){return e*=this.itemSize,this.normalized&&(t=bn(t,this.array),n=bn(n,this.array),r=bn(r,this.array)),this.array[e+0]=t,this.array[e+1]=n,this.array[e+2]=r,this}setXYZW(e,t,n,r,s){return e*=this.itemSize,this.normalized&&(t=bn(t,this.array),n=bn(n,this.array),r=bn(r,this.array),s=bn(s,this.array)),this.array[e+0]=t,this.array[e+1]=n,this.array[e+2]=r,this.array[e+3]=s,this}onUpload(e){return this.onUploadCallback=e,this}clone(){return new this.constructor(this.array,this.itemSize).copy(this)}toJSON(){let e={itemSize:this.itemSize,type:this.array.constructor.name,array:Array.from(this.array),normalized:this.normalized};return this.name!==""&&(e.name=this.name),this.usage!==uu&&(e.usage=this.usage),e}};var ks=class extends mt{constructor(e,t,n){super(new Uint16Array(e),t,n)}};var nr=class extends mt{constructor(e,t,n){super(new Uint32Array(e),t,n)}};var tn=class extends mt{constructor(e,t,n){super(new Float32Array(e),t,n)}},Vm=0,Ln=new Xe,eu=new nn,Dr=new k,Cn=new Ut,Ds=new Ut,en=new k,Bt=class i extends di{constructor(){super(),this.isBufferGeometry=!0,Object.defineProperty(this,"id",{value:Vm++}),this.uuid=la(),this.name="",this.type="BufferGeometry",this.index=null,this.indirect=null,this.attributes={},this.morphAttributes={},this.morphTargetsRelative=!1,this.groups=[],this.boundingBox=null,this.boundingSphere=null,this.drawRange={start:0,count:1/0},this.userData={}}getIndex(){return this.index}setIndex(e){return Array.isArray(e)?this.index=new(Iu(e)?nr:ks)(e,1):this.index=e,this}setIndirect(e){return this.indirect=e,this}getIndirect(){return this.indirect}getAttribute(e){return this.attributes[e]}setAttribute(e,t){return this.attributes[e]=t,this}deleteAttribute(e){return delete this.attributes[e],this}hasAttribute(e){return this.attributes[e]!==void 0}addGroup(e,t,n=0){this.groups.push({start:e,count:t,materialIndex:n})}clearGroups(){this.groups=[]}setDrawRange(e,t){this.drawRange.start=e,this.drawRange.count=t}applyMatrix4(e){let t=this.attributes.position;t!==void 0&&(t.applyMatrix4(e),t.needsUpdate=!0);let n=this.attributes.normal;if(n!==void 0){let s=new et().getNormalMatrix(e);n.applyNormalMatrix(s),n.needsUpdate=!0}let r=this.attributes.tangent;return r!==void 0&&(r.transformDirection(e),r.needsUpdate=!0),this.boundingBox!==null&&this.computeBoundingBox(),this.boundingSphere!==null&&this.computeBoundingSphere(),this}applyQuaternion(e){return Ln.makeRotationFromQuaternion(e),this.applyMatrix4(Ln),this}rotateX(e){return Ln.makeRotationX(e),this.applyMatrix4(Ln),this}rotateY(e){return Ln.makeRotationY(e),this.applyMatrix4(Ln),this}rotateZ(e){return Ln.makeRotationZ(e),this.applyMatrix4(Ln),this}translate(e,t,n){return Ln.makeTranslation(e,t,n),this.applyMatrix4(Ln),this}scale(e,t,n){return Ln.makeScale(e,t,n),this.applyMatrix4(Ln),this}lookAt(e){return eu.lookAt(e),eu.updateMatrix(),this.applyMatrix4(eu.matrix),this}center(){return this.computeBoundingBox(),this.boundingBox.getCenter(Dr).negate(),this.translate(Dr.x,Dr.y,Dr.z),this}setFromPoints(e){let t=this.getAttribute("position");if(t===void 0){let n=[];for(let r=0,s=e.length;r<s;r++){let a=e[r];n.push(a.x,a.y,a.z||0)}this.setAttribute("position",new tn(n,3))}else{let n=Math.min(e.length,t.count);for(let r=0;r<n;r++){let s=e[r];t.setXYZ(r,s.x,s.y,s.z||0)}e.length>t.count&&Ze("BufferGeometry: Buffer size too small for points data. Use .dispose() and create a new geometry."),t.needsUpdate=!0}return this}computeBoundingBox(){this.boundingBox===null&&(this.boundingBox=new Ut);let e=this.attributes.position,t=this.morphAttributes.position;if(e&&e.isGLBufferAttribute){ut("BufferGeometry.computeBoundingBox(): GLBufferAttribute requires a manual bounding box.",this),this.boundingBox.set(new k(-1/0,-1/0,-1/0),new k(1/0,1/0,1/0));return}if(e!==void 0){if(this.boundingBox.setFromBufferAttribute(e),t)for(let n=0,r=t.length;n<r;n++){let s=t[n];Cn.setFromBufferAttribute(s),this.morphTargetsRelative?(en.addVectors(this.boundingBox.min,Cn.min),this.boundingBox.expandByPoint(en),en.addVectors(this.boundingBox.max,Cn.max),this.boundingBox.expandByPoint(en)):(this.boundingBox.expandByPoint(Cn.min),this.boundingBox.expandByPoint(Cn.max))}}else this.boundingBox.makeEmpty();(isNaN(this.boundingBox.min.x)||isNaN(this.boundingBox.min.y)||isNaN(this.boundingBox.min.z))&&ut('BufferGeometry.computeBoundingBox(): Computed min/max have NaN values. The "position" attribute is likely to have NaN values.',this)}computeBoundingSphere(){this.boundingSphere===null&&(this.boundingSphere=new Wr);let e=this.attributes.position,t=this.morphAttributes.position;if(e&&e.isGLBufferAttribute){ut("BufferGeometry.computeBoundingSphere(): GLBufferAttribute requires a manual bounding sphere.",this),this.boundingSphere.set(new k,1/0);return}if(e){let n=this.boundingSphere.center;if(Cn.setFromBufferAttribute(e),t)for(let s=0,a=t.length;s<a;s++){let o=t[s];Ds.setFromBufferAttribute(o),this.morphTargetsRelative?(en.addVectors(Cn.min,Ds.min),Cn.expandByPoint(en),en.addVectors(Cn.max,Ds.max),Cn.expandByPoint(en)):(Cn.expandByPoint(Ds.min),Cn.expandByPoint(Ds.max))}Cn.getCenter(n);let r=0;for(let s=0,a=e.count;s<a;s++)en.fromBufferAttribute(e,s),r=Math.max(r,n.distanceToSquared(en));if(t)for(let s=0,a=t.length;s<a;s++){let o=t[s],c=this.morphTargetsRelative;for(let u=0,f=o.count;u<f;u++)en.fromBufferAttribute(o,u),c&&(Dr.fromBufferAttribute(e,u),en.add(Dr)),r=Math.max(r,n.distanceToSquared(en))}this.boundingSphere.radius=Math.sqrt(r),isNaN(this.boundingSphere.radius)&&ut('BufferGeometry.computeBoundingSphere(): Computed radius is NaN. The "position" attribute is likely to have NaN values.',this)}}computeTangents(){let e=this.index,t=this.attributes;if(e===null||t.position===void 0||t.normal===void 0||t.uv===void 0){ut("BufferGeometry: .computeTangents() failed. Missing required attributes (index, position, normal or uv)");return}let n=t.position,r=t.normal,s=t.uv;this.hasAttribute("tangent")===!1&&this.setAttribute("tangent",new mt(new Float32Array(4*n.count),4));let a=this.getAttribute("tangent"),o=[],c=[];for(let D=0;D<n.count;D++)o[D]=new k,c[D]=new k;let u=new k,f=new k,h=new k,l=new Le,p=new Le,g=new Le,b=new k,m=new k;function d(D,T,S){u.fromBufferAttribute(n,D),f.fromBufferAttribute(n,T),h.fromBufferAttribute(n,S),l.fromBufferAttribute(s,D),p.fromBufferAttribute(s,T),g.fromBufferAttribute(s,S),f.sub(u),h.sub(u),p.sub(l),g.sub(l);let P=1/(p.x*g.y-g.x*p.y);isFinite(P)&&(b.copy(f).multiplyScalar(g.y).addScaledVector(h,-p.y).multiplyScalar(P),m.copy(h).multiplyScalar(p.x).addScaledVector(f,-g.x).multiplyScalar(P),o[D].add(b),o[T].add(b),o[S].add(b),c[D].add(m),c[T].add(m),c[S].add(m))}let _=this.groups;_.length===0&&(_=[{start:0,count:e.count}]);for(let D=0,T=_.length;D<T;++D){let S=_[D],P=S.start,L=S.count;for(let O=P,H=P+L;O<H;O+=3)d(e.getX(O+0),e.getX(O+1),e.getX(O+2))}let y=new k,M=new k,w=new k,A=new k;function I(D){w.fromBufferAttribute(r,D),A.copy(w);let T=o[D];y.copy(T),y.sub(w.multiplyScalar(w.dot(T))).normalize(),M.crossVectors(A,T);let P=M.dot(c[D])<0?-1:1;a.setXYZW(D,y.x,y.y,y.z,P)}for(let D=0,T=_.length;D<T;++D){let S=_[D],P=S.start,L=S.count;for(let O=P,H=P+L;O<H;O+=3)I(e.getX(O+0)),I(e.getX(O+1)),I(e.getX(O+2))}}computeVertexNormals(){let e=this.index,t=this.getAttribute("position");if(t!==void 0){let n=this.getAttribute("normal");if(n===void 0)n=new mt(new Float32Array(t.count*3),3),this.setAttribute("normal",n);else for(let l=0,p=n.count;l<p;l++)n.setXYZ(l,0,0,0);let r=new k,s=new k,a=new k,o=new k,c=new k,u=new k,f=new k,h=new k;if(e)for(let l=0,p=e.count;l<p;l+=3){let g=e.getX(l+0),b=e.getX(l+1),m=e.getX(l+2);r.fromBufferAttribute(t,g),s.fromBufferAttribute(t,b),a.fromBufferAttribute(t,m),f.subVectors(a,s),h.subVectors(r,s),f.cross(h),o.fromBufferAttribute(n,g),c.fromBufferAttribute(n,b),u.fromBufferAttribute(n,m),o.add(f),c.add(f),u.add(f),n.setXYZ(g,o.x,o.y,o.z),n.setXYZ(b,c.x,c.y,c.z),n.setXYZ(m,u.x,u.y,u.z)}else for(let l=0,p=t.count;l<p;l+=3)r.fromBufferAttribute(t,l+0),s.fromBufferAttribute(t,l+1),a.fromBufferAttribute(t,l+2),f.subVectors(a,s),h.subVectors(r,s),f.cross(h),n.setXYZ(l+0,f.x,f.y,f.z),n.setXYZ(l+1,f.x,f.y,f.z),n.setXYZ(l+2,f.x,f.y,f.z);this.normalizeNormals(),n.needsUpdate=!0}}normalizeNormals(){let e=this.attributes.normal;for(let t=0,n=e.count;t<n;t++)en.fromBufferAttribute(e,t),en.normalize(),e.setXYZ(t,en.x,en.y,en.z)}toNonIndexed(){function e(o,c){let u=o.array,f=o.itemSize,h=o.normalized,l=new u.constructor(c.length*f),p=0,g=0;for(let b=0,m=c.length;b<m;b++){o.isInterleavedBufferAttribute?p=c[b]*o.data.stride+o.offset:p=c[b]*f;for(let d=0;d<f;d++)l[g++]=u[p++]}return new mt(l,f,h)}if(this.index===null)return Ze("BufferGeometry.toNonIndexed(): BufferGeometry is already non-indexed."),this;let t=new i,n=this.index.array,r=this.attributes;for(let o in r){let c=r[o],u=e(c,n);t.setAttribute(o,u)}let s=this.morphAttributes;for(let o in s){let c=[],u=s[o];for(let f=0,h=u.length;f<h;f++){let l=u[f],p=e(l,n);c.push(p)}t.morphAttributes[o]=c}t.morphTargetsRelative=this.morphTargetsRelative;let a=this.groups;for(let o=0,c=a.length;o<c;o++){let u=a[o];t.addGroup(u.start,u.count,u.materialIndex)}return t}toJSON(){let e={metadata:{version:4.7,type:"BufferGeometry",generator:"BufferGeometry.toJSON"}};if(e.uuid=this.uuid,e.type=this.type,this.name!==""&&(e.name=this.name),Object.keys(this.userData).length>0&&(e.userData=this.userData),this.parameters!==void 0){let c=this.parameters;for(let u in c)c[u]!==void 0&&(e[u]=c[u]);return e}e.data={attributes:{}};let t=this.index;t!==null&&(e.data.index={type:t.array.constructor.name,array:Array.prototype.slice.call(t.array)});let n=this.attributes;for(let c in n){let u=n[c];e.data.attributes[c]=u.toJSON(e.data)}let r={},s=!1;for(let c in this.morphAttributes){let u=this.morphAttributes[c],f=[];for(let h=0,l=u.length;h<l;h++){let p=u[h];f.push(p.toJSON(e.data))}f.length>0&&(r[c]=f,s=!0)}s&&(e.data.morphAttributes=r,e.data.morphTargetsRelative=this.morphTargetsRelative);let a=this.groups;a.length>0&&(e.data.groups=JSON.parse(JSON.stringify(a)));let o=this.boundingSphere;return o!==null&&(e.data.boundingSphere=o.toJSON()),e}clone(){return new this.constructor().copy(this)}copy(e){this.index=null,this.attributes={},this.morphAttributes={},this.groups=[],this.boundingBox=null,this.boundingSphere=null;let t={};this.name=e.name;let n=e.index;n!==null&&this.setIndex(n.clone());let r=e.attributes;for(let u in r){let f=r[u];this.setAttribute(u,f.clone(t))}let s=e.morphAttributes;for(let u in s){let f=[],h=s[u];for(let l=0,p=h.length;l<p;l++)f.push(h[l].clone(t));this.morphAttributes[u]=f}this.morphTargetsRelative=e.morphTargetsRelative;let a=e.groups;for(let u=0,f=a.length;u<f;u++){let h=a[u];this.addGroup(h.start,h.count,h.materialIndex)}let o=e.boundingBox;o!==null&&(this.boundingBox=o.clone());let c=e.boundingSphere;return c!==null&&(this.boundingSphere=c.clone()),this.drawRange.start=e.drawRange.start,this.drawRange.count=e.drawRange.count,this.userData=e.userData,this}dispose(){this.dispatchEvent({type:"dispose"})}},$h=new Xe,Ji=new Xr,Xa=new Wr,Jh=new k,qa=new k,Ya=new k,Za=new k,tu=new k,$a=new k,Kh=new k,Ja=new k,rn=class extends nn{constructor(e=new Bt,t=new tr){super(),this.isMesh=!0,this.type="Mesh",this.geometry=e,this.material=t,this.morphTargetDictionary=void 0,this.morphTargetInfluences=void 0,this.count=1,this.updateMorphTargets()}copy(e,t){return super.copy(e,t),e.morphTargetInfluences!==void 0&&(this.morphTargetInfluences=e.morphTargetInfluences.slice()),e.morphTargetDictionary!==void 0&&(this.morphTargetDictionary=Object.assign({},e.morphTargetDictionary)),this.material=Array.isArray(e.material)?e.material.slice():e.material,this.geometry=e.geometry,this}updateMorphTargets(){let t=this.geometry.morphAttributes,n=Object.keys(t);if(n.length>0){let r=t[n[0]];if(r!==void 0){this.morphTargetInfluences=[],this.morphTargetDictionary={};for(let s=0,a=r.length;s<a;s++){let o=r[s].name||String(s);this.morphTargetInfluences.push(0),this.morphTargetDictionary[o]=s}}}}getVertexPosition(e,t){let n=this.geometry,r=n.attributes.position,s=n.morphAttributes.position,a=n.morphTargetsRelative;t.fromBufferAttribute(r,e);let o=this.morphTargetInfluences;if(s&&o){$a.set(0,0,0);for(let c=0,u=s.length;c<u;c++){let f=o[c],h=s[c];f!==0&&(tu.fromBufferAttribute(h,e),a?$a.addScaledVector(tu,f):$a.addScaledVector(tu.sub(t),f))}t.add($a)}return t}raycast(e,t){let n=this.geometry,r=this.material,s=this.matrixWorld;r!==void 0&&(n.boundingSphere===null&&n.computeBoundingSphere(),Xa.copy(n.boundingSphere),Xa.applyMatrix4(s),Ji.copy(e.ray).recast(e.near),!(Xa.containsPoint(Ji.origin)===!1&&(Ji.intersectSphere(Xa,Jh)===null||Ji.origin.distanceToSquared(Jh)>(e.far-e.near)**2))&&($h.copy(s).invert(),Ji.copy(e.ray).applyMatrix4($h),!(n.boundingBox!==null&&Ji.intersectsBox(n.boundingBox)===!1)&&this._computeIntersections(e,t,Ji)))}_computeIntersections(e,t,n){let r,s=this.geometry,a=this.material,o=s.index,c=s.attributes.position,u=s.attributes.uv,f=s.attributes.uv1,h=s.attributes.normal,l=s.groups,p=s.drawRange;if(o!==null)if(Array.isArray(a))for(let g=0,b=l.length;g<b;g++){let m=l[g],d=a[m.materialIndex],_=Math.max(m.start,p.start),y=Math.min(o.count,Math.min(m.start+m.count,p.start+p.count));for(let M=_,w=y;M<w;M+=3){let A=o.getX(M),I=o.getX(M+1),D=o.getX(M+2);r=Ka(this,d,e,n,u,f,h,A,I,D),r&&(r.faceIndex=Math.floor(M/3),r.face.materialIndex=m.materialIndex,t.push(r))}}else{let g=Math.max(0,p.start),b=Math.min(o.count,p.start+p.count);for(let m=g,d=b;m<d;m+=3){let _=o.getX(m),y=o.getX(m+1),M=o.getX(m+2);r=Ka(this,a,e,n,u,f,h,_,y,M),r&&(r.faceIndex=Math.floor(m/3),t.push(r))}}else if(c!==void 0)if(Array.isArray(a))for(let g=0,b=l.length;g<b;g++){let m=l[g],d=a[m.materialIndex],_=Math.max(m.start,p.start),y=Math.min(c.count,Math.min(m.start+m.count,p.start+p.count));for(let M=_,w=y;M<w;M+=3){let A=M,I=M+1,D=M+2;r=Ka(this,d,e,n,u,f,h,A,I,D),r&&(r.faceIndex=Math.floor(M/3),r.face.materialIndex=m.materialIndex,t.push(r))}}else{let g=Math.max(0,p.start),b=Math.min(c.count,p.start+p.count);for(let m=g,d=b;m<d;m+=3){let _=m,y=m+1,M=m+2;r=Ka(this,a,e,n,u,f,h,_,y,M),r&&(r.faceIndex=Math.floor(m/3),t.push(r))}}}};function Hm(i,e,t,n,r,s,a,o){let c;if(e.side===Zt?c=n.intersectTriangle(a,s,r,!0,o):c=n.intersectTriangle(r,s,a,e.side===Mn,o),c===null)return null;Ja.copy(o),Ja.applyMatrix4(i.matrixWorld);let u=t.ray.origin.distanceTo(Ja);return u<t.near||u>t.far?null:{distance:u,point:Ja.clone(),object:i}}function Ka(i,e,t,n,r,s,a,o,c,u){i.getVertexPosition(o,qa),i.getVertexPosition(c,Ya),i.getVertexPosition(u,Za);let f=Hm(i,e,t,n,qa,Ya,Za,Kh);if(f){let h=new k;un.getBarycoord(Kh,qa,Ya,Za,h),r&&(f.uv=un.getInterpolatedAttribute(r,o,c,u,h,new Le)),s&&(f.uv1=un.getInterpolatedAttribute(s,o,c,u,h,new Le)),a&&(f.normal=un.getInterpolatedAttribute(a,o,c,u,h,new k),f.normal.dot(n.direction)>0&&f.normal.multiplyScalar(-1));let l={a:o,b:c,c:u,normal:new k,materialIndex:0};un.getNormal(qa,Ya,Za,l.normal),f.face=l,f.barycoord=h}return f}var qr=class i extends Bt{constructor(e=1,t=1,n=1,r=1,s=1,a=1){super(),this.type="BoxGeometry",this.parameters={width:e,height:t,depth:n,widthSegments:r,heightSegments:s,depthSegments:a};let o=this;r=Math.floor(r),s=Math.floor(s),a=Math.floor(a);let c=[],u=[],f=[],h=[],l=0,p=0;g("z","y","x",-1,-1,n,t,e,a,s,0),g("z","y","x",1,-1,n,t,-e,a,s,1),g("x","z","y",1,1,e,n,t,r,a,2),g("x","z","y",1,-1,e,n,-t,r,a,3),g("x","y","z",1,-1,e,t,n,r,s,4),g("x","y","z",-1,-1,e,t,-n,r,s,5),this.setIndex(c),this.setAttribute("position",new tn(u,3)),this.setAttribute("normal",new tn(f,3)),this.setAttribute("uv",new tn(h,2));function g(b,m,d,_,y,M,w,A,I,D,T){let S=M/I,P=w/D,L=M/2,O=w/2,H=A/2,q=I+1,Y=D+1,he=0,j=0,le=new k;for(let ce=0;ce<Y;ce++){let we=ce*P-O;for(let Ce=0;Ce<q;Ce++){let ke=Ce*S-L;le[b]=ke*_,le[m]=we*y,le[d]=H,u.push(le.x,le.y,le.z),le[b]=0,le[m]=0,le[d]=A>0?1:-1,f.push(le.x,le.y,le.z),h.push(Ce/I),h.push(1-ce/D),he+=1}}for(let ce=0;ce<D;ce++)for(let we=0;we<I;we++){let Ce=l+we+q*ce,ke=l+we+q*(ce+1),ct=l+(we+1)+q*(ce+1),nt=l+(we+1)+q*ce;c.push(Ce,ke,nt),c.push(ke,ct,nt),j+=6}o.addGroup(p,j,T),p+=j,l+=he}}copy(e){return super.copy(e),this.parameters=Object.assign({},e.parameters),this}static fromJSON(e){return new i(e.width,e.height,e.depth,e.widthSegments,e.heightSegments,e.depthSegments)}};function cr(i){let e={};for(let t in i){e[t]={};for(let n in i[t]){let r=i[t][n];r&&(r.isColor||r.isMatrix3||r.isMatrix4||r.isVector2||r.isVector3||r.isVector4||r.isTexture||r.isQuaternion)?r.isRenderTargetTexture?(Ze("UniformsUtils: Textures of render targets cannot be cloned via cloneUniforms() or mergeUniforms()."),e[t][n]=null):e[t][n]=r.clone():Array.isArray(r)?e[t][n]=r.slice():e[t][n]=r}}return e}function pn(i){let e={};for(let t=0;t<i.length;t++){let n=cr(i[t]);for(let r in n)e[r]=n[r]}return e}function Gm(i){let e=[];for(let t=0;t<i.length;t++)e.push(i[t].clone());return e}function Du(i){let e=i.getRenderTarget();return e===null?i.outputColorSpace:e.isXRRenderTarget===!0?e.texture.colorSpace:dt.workingColorSpace}var Zf={clone:cr,merge:pn},Wm=`void main() {
	gl_Position = projectionMatrix * modelViewMatrix * vec4( position, 1.0 );
}`,Xm=`void main() {
	gl_FragColor = vec4( 1.0, 0.0, 0.0, 1.0 );
}`,Xt=class extends Ii{constructor(e){super(),this.isShaderMaterial=!0,this.type="ShaderMaterial",this.defines={},this.uniforms={},this.uniformsGroups=[],this.vertexShader=Wm,this.fragmentShader=Xm,this.linewidth=1,this.wireframe=!1,this.wireframeLinewidth=1,this.fog=!1,this.lights=!1,this.clipping=!1,this.forceSinglePass=!0,this.extensions={clipCullDistance:!1,multiDraw:!1},this.defaultAttributeValues={color:[1,1,1],uv:[0,0],uv1:[0,0]},this.index0AttributeName=void 0,this.uniformsNeedUpdate=!1,this.glslVersion=null,e!==void 0&&this.setValues(e)}copy(e){return super.copy(e),this.fragmentShader=e.fragmentShader,this.vertexShader=e.vertexShader,this.uniforms=cr(e.uniforms),this.uniformsGroups=Gm(e.uniformsGroups),this.defines=Object.assign({},e.defines),this.wireframe=e.wireframe,this.wireframeLinewidth=e.wireframeLinewidth,this.fog=e.fog,this.lights=e.lights,this.clipping=e.clipping,this.extensions=Object.assign({},e.extensions),this.glslVersion=e.glslVersion,this}toJSON(e){let t=super.toJSON(e);t.glslVersion=this.glslVersion,t.uniforms={};for(let r in this.uniforms){let a=this.uniforms[r].value;a&&a.isTexture?t.uniforms[r]={type:"t",value:a.toJSON(e).uuid}:a&&a.isColor?t.uniforms[r]={type:"c",value:a.getHex()}:a&&a.isVector2?t.uniforms[r]={type:"v2",value:a.toArray()}:a&&a.isVector3?t.uniforms[r]={type:"v3",value:a.toArray()}:a&&a.isVector4?t.uniforms[r]={type:"v4",value:a.toArray()}:a&&a.isMatrix3?t.uniforms[r]={type:"m3",value:a.toArray()}:a&&a.isMatrix4?t.uniforms[r]={type:"m4",value:a.toArray()}:t.uniforms[r]={value:a}}Object.keys(this.defines).length>0&&(t.defines=this.defines),t.vertexShader=this.vertexShader,t.fragmentShader=this.fragmentShader,t.lights=this.lights,t.clipping=this.clipping;let n={};for(let r in this.extensions)this.extensions[r]===!0&&(n[r]=!0);return Object.keys(n).length>0&&(t.extensions=n),t}},Vs=class extends nn{constructor(){super(),this.isCamera=!0,this.type="Camera",this.matrixWorldInverse=new Xe,this.projectionMatrix=new Xe,this.projectionMatrixInverse=new Xe,this.coordinateSystem=Hn,this._reversedDepth=!1}get reversedDepth(){return this._reversedDepth}copy(e,t){return super.copy(e,t),this.matrixWorldInverse.copy(e.matrixWorldInverse),this.projectionMatrix.copy(e.projectionMatrix),this.projectionMatrixInverse.copy(e.projectionMatrixInverse),this.coordinateSystem=e.coordinateSystem,this}getWorldDirection(e){return super.getWorldDirection(e).negate()}updateMatrixWorld(e){super.updateMatrixWorld(e),this.matrixWorldInverse.copy(this.matrixWorld).invert()}updateWorldMatrix(e,t){super.updateWorldMatrix(e,t),this.matrixWorldInverse.copy(this.matrixWorld).invert()}clone(){return new this.constructor().copy(this)}},Ai=new k,Qh=new Le,jh=new Le,kt=class extends Vs{constructor(e=50,t=1,n=.1,r=2e3){super(),this.isPerspectiveCamera=!0,this.type="PerspectiveCamera",this.fov=e,this.zoom=1,this.near=n,this.far=r,this.focus=10,this.aspect=t,this.view=null,this.filmGauge=35,this.filmOffset=0,this.updateProjectionMatrix()}copy(e,t){return super.copy(e,t),this.fov=e.fov,this.zoom=e.zoom,this.near=e.near,this.far=e.far,this.focus=e.focus,this.aspect=e.aspect,this.view=e.view===null?null:Object.assign({},e.view),this.filmGauge=e.filmGauge,this.filmOffset=e.filmOffset,this}setFocalLength(e){let t=.5*this.getFilmHeight()/e;this.fov=Bs*2*Math.atan(t),this.updateProjectionMatrix()}getFocalLength(){let e=Math.tan(Ll*.5*this.fov);return .5*this.getFilmHeight()/e}getEffectiveFOV(){return Bs*2*Math.atan(Math.tan(Ll*.5*this.fov)/this.zoom)}getFilmWidth(){return this.filmGauge*Math.min(this.aspect,1)}getFilmHeight(){return this.filmGauge/Math.max(this.aspect,1)}getViewBounds(e,t,n){Ai.set(-1,-1,.5).applyMatrix4(this.projectionMatrixInverse),t.set(Ai.x,Ai.y).multiplyScalar(-e/Ai.z),Ai.set(1,1,.5).applyMatrix4(this.projectionMatrixInverse),n.set(Ai.x,Ai.y).multiplyScalar(-e/Ai.z)}getViewSize(e,t){return this.getViewBounds(e,Qh,jh),t.subVectors(jh,Qh)}setViewOffset(e,t,n,r,s,a){this.aspect=e/t,this.view===null&&(this.view={enabled:!0,fullWidth:1,fullHeight:1,offsetX:0,offsetY:0,width:1,height:1}),this.view.enabled=!0,this.view.fullWidth=e,this.view.fullHeight=t,this.view.offsetX=n,this.view.offsetY=r,this.view.width=s,this.view.height=a,this.updateProjectionMatrix()}clearViewOffset(){this.view!==null&&(this.view.enabled=!1),this.updateProjectionMatrix()}updateProjectionMatrix(){let e=this.near,t=e*Math.tan(Ll*.5*this.fov)/this.zoom,n=2*t,r=this.aspect*n,s=-.5*r,a=this.view;if(this.view!==null&&this.view.enabled){let c=a.fullWidth,u=a.fullHeight;s+=a.offsetX*r/c,t-=a.offsetY*n/u,r*=a.width/c,n*=a.height/u}let o=this.filmOffset;o!==0&&(s+=e*o/this.getFilmWidth()),this.projectionMatrix.makePerspective(s,s+r,t,t-n,e,this.far,this.coordinateSystem,this.reversedDepth),this.projectionMatrixInverse.copy(this.projectionMatrix).invert()}toJSON(e){let t=super.toJSON(e);return t.object.fov=this.fov,t.object.zoom=this.zoom,t.object.near=this.near,t.object.far=this.far,t.object.focus=this.focus,t.object.aspect=this.aspect,this.view!==null&&(t.object.view=Object.assign({},this.view)),t.object.filmGauge=this.filmGauge,t.object.filmOffset=this.filmOffset,t}},Fr=-90,Lr=1,lo=class extends nn{constructor(e,t,n){super(),this.type="CubeCamera",this.renderTarget=n,this.coordinateSystem=null,this.activeMipmapLevel=0;let r=new kt(Fr,Lr,e,t);r.layers=this.layers,this.add(r);let s=new kt(Fr,Lr,e,t);s.layers=this.layers,this.add(s);let a=new kt(Fr,Lr,e,t);a.layers=this.layers,this.add(a);let o=new kt(Fr,Lr,e,t);o.layers=this.layers,this.add(o);let c=new kt(Fr,Lr,e,t);c.layers=this.layers,this.add(c);let u=new kt(Fr,Lr,e,t);u.layers=this.layers,this.add(u)}updateCoordinateSystem(){let e=this.coordinateSystem,t=this.children.concat(),[n,r,s,a,o,c]=t;for(let u of t)this.remove(u);if(e===Hn)n.up.set(0,1,0),n.lookAt(1,0,0),r.up.set(0,1,0),r.lookAt(-1,0,0),s.up.set(0,0,-1),s.lookAt(0,1,0),a.up.set(0,0,1),a.lookAt(0,-1,0),o.up.set(0,1,0),o.lookAt(0,0,1),c.up.set(0,1,0),c.lookAt(0,0,-1);else if(e===Us)n.up.set(0,-1,0),n.lookAt(-1,0,0),r.up.set(0,-1,0),r.lookAt(1,0,0),s.up.set(0,0,1),s.lookAt(0,1,0),a.up.set(0,0,-1),a.lookAt(0,-1,0),o.up.set(0,-1,0),o.lookAt(0,0,1),c.up.set(0,-1,0),c.lookAt(0,0,-1);else throw new Error("THREE.CubeCamera.updateCoordinateSystem(): Invalid coordinate system: "+e);for(let u of t)this.add(u),u.updateMatrixWorld()}update(e,t){this.parent===null&&this.updateMatrixWorld();let{renderTarget:n,activeMipmapLevel:r}=this;this.coordinateSystem!==e.coordinateSystem&&(this.coordinateSystem=e.coordinateSystem,this.updateCoordinateSystem());let[s,a,o,c,u,f]=this.children,h=e.getRenderTarget(),l=e.getActiveCubeFace(),p=e.getActiveMipmapLevel(),g=e.xr.enabled;e.xr.enabled=!1;let b=n.texture.generateMipmaps;n.texture.generateMipmaps=!1,e.setRenderTarget(n,0,r),e.render(t,s),e.setRenderTarget(n,1,r),e.render(t,a),e.setRenderTarget(n,2,r),e.render(t,o),e.setRenderTarget(n,3,r),e.render(t,c),e.setRenderTarget(n,4,r),e.render(t,u),n.texture.generateMipmaps=b,e.setRenderTarget(n,5,r),e.render(t,f),e.setRenderTarget(h,l,p),e.xr.enabled=g,n.texture.needsPMREMUpdate=!0}},Hs=class extends mn{constructor(e=[],t=ar,n,r,s,a,o,c,u,f){super(e,t,n,r,s,a,o,c,u,f),this.isCubeTexture=!0,this.flipY=!1}get images(){return this.image}set images(e){this.image=e}},uo=class extends Yt{constructor(e=1,t={}){super(e,e,t),this.isWebGLCubeRenderTarget=!0;let n={width:e,height:e,depth:1},r=[n,n,n,n,n,n];this.texture=new Hs(r),this._setTextureOptions(t),this.texture.isRenderTargetTexture=!0}fromEquirectangularTexture(e,t){this.texture.type=t.type,this.texture.colorSpace=t.colorSpace,this.texture.generateMipmaps=t.generateMipmaps,this.texture.minFilter=t.minFilter,this.texture.magFilter=t.magFilter;let n={uniforms:{tEquirect:{value:null}},vertexShader:`

				varying vec3 vWorldDirection;

				vec3 transformDirection( in vec3 dir, in mat4 matrix ) {

					return normalize( ( matrix * vec4( dir, 0.0 ) ).xyz );

				}

				void main() {

					vWorldDirection = transformDirection( position, modelMatrix );

					#include <begin_vertex>
					#include <project_vertex>

				}
			`,fragmentShader:`

				uniform sampler2D tEquirect;

				varying vec3 vWorldDirection;

				#include <common>

				void main() {

					vec3 direction = normalize( vWorldDirection );

					vec2 sampleUV = equirectUv( direction );

					gl_FragColor = texture2D( tEquirect, sampleUV );

				}
			`},r=new qr(5,5,5),s=new Xt({name:"CubemapFromEquirect",uniforms:cr(n.uniforms),vertexShader:n.vertexShader,fragmentShader:n.fragmentShader,side:Zt,blending:$t});s.uniforms.tEquirect.value=t;let a=new rn(r,s),o=t.minFilter;return t.minFilter===mi&&(t.minFilter=ft),new lo(1,10,this).update(e,a),t.minFilter=o,a.geometry.dispose(),a.material.dispose(),this}clear(e,t=!0,n=!0,r=!0){let s=e.getRenderTarget();for(let a=0;a<6;a++)e.setRenderTarget(this,a),e.clear(t,n,r);e.setRenderTarget(s)}},ji=class extends nn{constructor(){super(),this.isGroup=!0,this.type="Group"}},qm={type:"move"},Yr=class{constructor(){this._targetRay=null,this._grip=null,this._hand=null}getHandSpace(){return this._hand===null&&(this._hand=new ji,this._hand.matrixAutoUpdate=!1,this._hand.visible=!1,this._hand.joints={},this._hand.inputState={pinching:!1}),this._hand}getTargetRaySpace(){return this._targetRay===null&&(this._targetRay=new ji,this._targetRay.matrixAutoUpdate=!1,this._targetRay.visible=!1,this._targetRay.hasLinearVelocity=!1,this._targetRay.linearVelocity=new k,this._targetRay.hasAngularVelocity=!1,this._targetRay.angularVelocity=new k),this._targetRay}getGripSpace(){return this._grip===null&&(this._grip=new ji,this._grip.matrixAutoUpdate=!1,this._grip.visible=!1,this._grip.hasLinearVelocity=!1,this._grip.linearVelocity=new k,this._grip.hasAngularVelocity=!1,this._grip.angularVelocity=new k),this._grip}dispatchEvent(e){return this._targetRay!==null&&this._targetRay.dispatchEvent(e),this._grip!==null&&this._grip.dispatchEvent(e),this._hand!==null&&this._hand.dispatchEvent(e),this}connect(e){if(e&&e.hand){let t=this._hand;if(t)for(let n of e.hand.values())this._getHandJoint(t,n)}return this.dispatchEvent({type:"connected",data:e}),this}disconnect(e){return this.dispatchEvent({type:"disconnected",data:e}),this._targetRay!==null&&(this._targetRay.visible=!1),this._grip!==null&&(this._grip.visible=!1),this._hand!==null&&(this._hand.visible=!1),this}update(e,t,n){let r=null,s=null,a=null,o=this._targetRay,c=this._grip,u=this._hand;if(e&&t.session.visibilityState!=="visible-blurred"){if(u&&e.hand){a=!0;for(let b of e.hand.values()){let m=t.getJointPose(b,n),d=this._getHandJoint(u,b);m!==null&&(d.matrix.fromArray(m.transform.matrix),d.matrix.decompose(d.position,d.rotation,d.scale),d.matrixWorldNeedsUpdate=!0,d.jointRadius=m.radius),d.visible=m!==null}let f=u.joints["index-finger-tip"],h=u.joints["thumb-tip"],l=f.position.distanceTo(h.position),p=.02,g=.005;u.inputState.pinching&&l>p+g?(u.inputState.pinching=!1,this.dispatchEvent({type:"pinchend",handedness:e.handedness,target:this})):!u.inputState.pinching&&l<=p-g&&(u.inputState.pinching=!0,this.dispatchEvent({type:"pinchstart",handedness:e.handedness,target:this}))}else c!==null&&e.gripSpace&&(s=t.getPose(e.gripSpace,n),s!==null&&(c.matrix.fromArray(s.transform.matrix),c.matrix.decompose(c.position,c.rotation,c.scale),c.matrixWorldNeedsUpdate=!0,s.linearVelocity?(c.hasLinearVelocity=!0,c.linearVelocity.copy(s.linearVelocity)):c.hasLinearVelocity=!1,s.angularVelocity?(c.hasAngularVelocity=!0,c.angularVelocity.copy(s.angularVelocity)):c.hasAngularVelocity=!1));o!==null&&(r=t.getPose(e.targetRaySpace,n),r===null&&s!==null&&(r=s),r!==null&&(o.matrix.fromArray(r.transform.matrix),o.matrix.decompose(o.position,o.rotation,o.scale),o.matrixWorldNeedsUpdate=!0,r.linearVelocity?(o.hasLinearVelocity=!0,o.linearVelocity.copy(r.linearVelocity)):o.hasLinearVelocity=!1,r.angularVelocity?(o.hasAngularVelocity=!0,o.angularVelocity.copy(r.angularVelocity)):o.hasAngularVelocity=!1,this.dispatchEvent(qm)))}return o!==null&&(o.visible=r!==null),c!==null&&(c.visible=s!==null),u!==null&&(u.visible=a!==null),this}_getHandJoint(e,t){if(e.joints[t.jointName]===void 0){let n=new ji;n.matrixAutoUpdate=!1,n.visible=!1,e.joints[t.jointName]=n,e.add(n)}return e.joints[t.jointName]}};var ir=class extends nn{constructor(){super(),this.isScene=!0,this.type="Scene",this.background=null,this.environment=null,this.fog=null,this.backgroundBlurriness=0,this.backgroundIntensity=1,this.backgroundRotation=new Xn,this.environmentIntensity=1,this.environmentRotation=new Xn,this.overrideMaterial=null,typeof __THREE_DEVTOOLS__<"u"&&__THREE_DEVTOOLS__.dispatchEvent(new CustomEvent("observe",{detail:this}))}copy(e,t){return super.copy(e,t),e.background!==null&&(this.background=e.background.clone()),e.environment!==null&&(this.environment=e.environment.clone()),e.fog!==null&&(this.fog=e.fog.clone()),this.backgroundBlurriness=e.backgroundBlurriness,this.backgroundIntensity=e.backgroundIntensity,this.backgroundRotation.copy(e.backgroundRotation),this.environmentIntensity=e.environmentIntensity,this.environmentRotation.copy(e.environmentRotation),e.overrideMaterial!==null&&(this.overrideMaterial=e.overrideMaterial.clone()),this.matrixAutoUpdate=e.matrixAutoUpdate,this}toJSON(e){let t=super.toJSON(e);return this.fog!==null&&(t.object.fog=this.fog.toJSON()),this.backgroundBlurriness>0&&(t.object.backgroundBlurriness=this.backgroundBlurriness),this.backgroundIntensity!==1&&(t.object.backgroundIntensity=this.backgroundIntensity),t.object.backgroundRotation=this.backgroundRotation.toArray(),this.environmentIntensity!==1&&(t.object.environmentIntensity=this.environmentIntensity),t.object.environmentRotation=this.environmentRotation.toArray(),t}};var St=class extends mn{constructor(e=null,t=1,n=1,r,s,a,o,c,u=je,f=je,h,l){super(null,a,o,c,u,f,r,s,h,l),this.isDataTexture=!0,this.image={data:e,width:t,height:n},this.generateMipmaps=!1,this.flipY=!1,this.unpackAlignment=1}};var nu=new k,Ym=new k,Zm=new et,Sn=class{constructor(e=new k(1,0,0),t=0){this.isPlane=!0,this.normal=e,this.constant=t}set(e,t){return this.normal.copy(e),this.constant=t,this}setComponents(e,t,n,r){return this.normal.set(e,t,n),this.constant=r,this}setFromNormalAndCoplanarPoint(e,t){return this.normal.copy(e),this.constant=-t.dot(this.normal),this}setFromCoplanarPoints(e,t,n){let r=nu.subVectors(n,t).cross(Ym.subVectors(e,t)).normalize();return this.setFromNormalAndCoplanarPoint(r,e),this}copy(e){return this.normal.copy(e.normal),this.constant=e.constant,this}normalize(){let e=1/this.normal.length();return this.normal.multiplyScalar(e),this.constant*=e,this}negate(){return this.constant*=-1,this.normal.negate(),this}distanceToPoint(e){return this.normal.dot(e)+this.constant}distanceToSphere(e){return this.distanceToPoint(e.center)-e.radius}projectPoint(e,t){return t.copy(e).addScaledVector(this.normal,-this.distanceToPoint(e))}intersectLine(e,t){let n=e.delta(nu),r=this.normal.dot(n);if(r===0)return this.distanceToPoint(e.start)===0?t.copy(e.start):null;let s=-(e.start.dot(this.normal)+this.constant)/r;return s<0||s>1?null:t.copy(e.start).addScaledVector(n,s)}intersectsLine(e){let t=this.distanceToPoint(e.start),n=this.distanceToPoint(e.end);return t<0&&n>0||n<0&&t>0}intersectsBox(e){return e.intersectsPlane(this)}intersectsSphere(e){return e.intersectsPlane(this)}coplanarPoint(e){return e.copy(this.normal).multiplyScalar(-this.constant)}applyMatrix4(e,t){let n=t||Zm.getNormalMatrix(e),r=this.coplanarPoint(nu).applyMatrix4(e),s=this.normal.applyMatrix3(n).normalize();return this.constant=-r.dot(s),this}translate(e){return this.constant-=e.dot(this.normal),this}equals(e){return e.normal.equals(this.normal)&&e.constant===this.constant}clone(){return new this.constructor().copy(this)}},Ki=new Wr,$m=new Le(.5,.5),Qa=new k,Zr=class{constructor(e=new Sn,t=new Sn,n=new Sn,r=new Sn,s=new Sn,a=new Sn){this.planes=[e,t,n,r,s,a]}set(e,t,n,r,s,a){let o=this.planes;return o[0].copy(e),o[1].copy(t),o[2].copy(n),o[3].copy(r),o[4].copy(s),o[5].copy(a),this}copy(e){let t=this.planes;for(let n=0;n<6;n++)t[n].copy(e.planes[n]);return this}setFromProjectionMatrix(e,t=Hn,n=!1){let r=this.planes,s=e.elements,a=s[0],o=s[1],c=s[2],u=s[3],f=s[4],h=s[5],l=s[6],p=s[7],g=s[8],b=s[9],m=s[10],d=s[11],_=s[12],y=s[13],M=s[14],w=s[15];if(r[0].setComponents(u-a,p-f,d-g,w-_).normalize(),r[1].setComponents(u+a,p+f,d+g,w+_).normalize(),r[2].setComponents(u+o,p+h,d+b,w+y).normalize(),r[3].setComponents(u-o,p-h,d-b,w-y).normalize(),n)r[4].setComponents(c,l,m,M).normalize(),r[5].setComponents(u-c,p-l,d-m,w-M).normalize();else if(r[4].setComponents(u-c,p-l,d-m,w-M).normalize(),t===Hn)r[5].setComponents(u+c,p+l,d+m,w+M).normalize();else if(t===Us)r[5].setComponents(c,l,m,M).normalize();else throw new Error("THREE.Frustum.setFromProjectionMatrix(): Invalid coordinate system: "+t);return this}intersectsObject(e){if(e.boundingSphere!==void 0)e.boundingSphere===null&&e.computeBoundingSphere(),Ki.copy(e.boundingSphere).applyMatrix4(e.matrixWorld);else{let t=e.geometry;t.boundingSphere===null&&t.computeBoundingSphere(),Ki.copy(t.boundingSphere).applyMatrix4(e.matrixWorld)}return this.intersectsSphere(Ki)}intersectsSprite(e){Ki.center.set(0,0,0);let t=$m.distanceTo(e.center);return Ki.radius=.7071067811865476+t,Ki.applyMatrix4(e.matrixWorld),this.intersectsSphere(Ki)}intersectsSphere(e){let t=this.planes,n=e.center,r=-e.radius;for(let s=0;s<6;s++)if(t[s].distanceToPoint(n)<r)return!1;return!0}intersectsBox(e){let t=this.planes;for(let n=0;n<6;n++){let r=t[n];if(Qa.x=r.normal.x>0?e.max.x:e.min.x,Qa.y=r.normal.y>0?e.max.y:e.min.y,Qa.z=r.normal.z>0?e.max.z:e.min.z,r.distanceToPoint(Qa)<0)return!1}return!0}containsPoint(e){let t=this.planes;for(let n=0;n<6;n++)if(t[n].distanceToPoint(e)<0)return!1;return!0}clone(){return new this.constructor().copy(this)}};var Gs=class extends mn{constructor(e,t,n=xn,r,s,a,o=je,c=je,u,f=kr,h=1){if(f!==kr&&f!==Qr)throw new Error("DepthTexture format must be either THREE.DepthFormat or THREE.DepthStencilFormat");let l={width:e,height:t,depth:h};super(l,r,s,a,o,c,f,n,u),this.isDepthTexture=!0,this.flipY=!1,this.generateMipmaps=!1,this.compareFunction=null}copy(e){return super.copy(e),this.source=new Ci(Object.assign({},e.image)),this.compareFunction=e.compareFunction,this}toJSON(e){let t=super.toJSON(e);return this.compareFunction!==null&&(t.compareFunction=this.compareFunction),t}},Ws=class extends mn{constructor(e=null){super(),this.sourceTexture=e,this.isExternalTexture=!0}copy(e){return super.copy(e),this.sourceTexture=e.sourceTexture,this}};var Xs=class i extends Bt{constructor(e=1,t=1,n=1,r=1){super(),this.type="PlaneGeometry",this.parameters={width:e,height:t,widthSegments:n,heightSegments:r};let s=e/2,a=t/2,o=Math.floor(n),c=Math.floor(r),u=o+1,f=c+1,h=e/o,l=t/c,p=[],g=[],b=[],m=[];for(let d=0;d<f;d++){let _=d*l-a;for(let y=0;y<u;y++){let M=y*h-s;g.push(M,-_,0),b.push(0,0,1),m.push(y/o),m.push(1-d/c)}}for(let d=0;d<c;d++)for(let _=0;_<o;_++){let y=_+u*d,M=_+u*(d+1),w=_+1+u*(d+1),A=_+1+u*d;p.push(y,M,A),p.push(M,w,A)}this.setIndex(p),this.setAttribute("position",new tn(g,3)),this.setAttribute("normal",new tn(b,3)),this.setAttribute("uv",new tn(m,2))}copy(e){return super.copy(e),this.parameters=Object.assign({},e.parameters),this}static fromJSON(e){return new i(e.width,e.height,e.widthSegments,e.heightSegments)}};var ho=class extends Ii{constructor(e){super(),this.isMeshStandardMaterial=!0,this.type="MeshStandardMaterial",this.defines={STANDARD:""},this.color=new Ye(16777215),this.roughness=1,this.metalness=0,this.map=null,this.lightMap=null,this.lightMapIntensity=1,this.aoMap=null,this.aoMapIntensity=1,this.emissive=new Ye(0),this.emissiveIntensity=1,this.emissiveMap=null,this.bumpMap=null,this.bumpScale=1,this.normalMap=null,this.normalMapType=Eu,this.normalScale=new Le(1,1),this.displacementMap=null,this.displacementScale=1,this.displacementBias=0,this.roughnessMap=null,this.metalnessMap=null,this.alphaMap=null,this.envMap=null,this.envMapRotation=new Xn,this.envMapIntensity=1,this.wireframe=!1,this.wireframeLinewidth=1,this.wireframeLinecap="round",this.wireframeLinejoin="round",this.flatShading=!1,this.fog=!0,this.setValues(e)}copy(e){return super.copy(e),this.defines={STANDARD:""},this.color.copy(e.color),this.roughness=e.roughness,this.metalness=e.metalness,this.map=e.map,this.lightMap=e.lightMap,this.lightMapIntensity=e.lightMapIntensity,this.aoMap=e.aoMap,this.aoMapIntensity=e.aoMapIntensity,this.emissive.copy(e.emissive),this.emissiveMap=e.emissiveMap,this.emissiveIntensity=e.emissiveIntensity,this.bumpMap=e.bumpMap,this.bumpScale=e.bumpScale,this.normalMap=e.normalMap,this.normalMapType=e.normalMapType,this.normalScale.copy(e.normalScale),this.displacementMap=e.displacementMap,this.displacementScale=e.displacementScale,this.displacementBias=e.displacementBias,this.roughnessMap=e.roughnessMap,this.metalnessMap=e.metalnessMap,this.alphaMap=e.alphaMap,this.envMap=e.envMap,this.envMapRotation.copy(e.envMapRotation),this.envMapIntensity=e.envMapIntensity,this.wireframe=e.wireframe,this.wireframeLinewidth=e.wireframeLinewidth,this.wireframeLinecap=e.wireframeLinecap,this.wireframeLinejoin=e.wireframeLinejoin,this.flatShading=e.flatShading,this.fog=e.fog,this}},qs=class extends ho{constructor(e){super(),this.isMeshPhysicalMaterial=!0,this.defines={STANDARD:"",PHYSICAL:""},this.type="MeshPhysicalMaterial",this.anisotropyRotation=0,this.anisotropyMap=null,this.clearcoatMap=null,this.clearcoatRoughness=0,this.clearcoatRoughnessMap=null,this.clearcoatNormalScale=new Le(1,1),this.clearcoatNormalMap=null,this.ior=1.5,Object.defineProperty(this,"reflectivity",{get:function(){return Ke(2.5*(this.ior-1)/(this.ior+1),0,1)},set:function(t){this.ior=(1+.4*t)/(1-.4*t)}}),this.iridescenceMap=null,this.iridescenceIOR=1.3,this.iridescenceThicknessRange=[100,400],this.iridescenceThicknessMap=null,this.sheenColor=new Ye(0),this.sheenColorMap=null,this.sheenRoughness=1,this.sheenRoughnessMap=null,this.transmissionMap=null,this.thickness=0,this.thicknessMap=null,this.attenuationDistance=1/0,this.attenuationColor=new Ye(1,1,1),this.specularIntensity=1,this.specularIntensityMap=null,this.specularColor=new Ye(1,1,1),this.specularColorMap=null,this._anisotropy=0,this._clearcoat=0,this._dispersion=0,this._iridescence=0,this._sheen=0,this._transmission=0,this.setValues(e)}get anisotropy(){return this._anisotropy}set anisotropy(e){this._anisotropy>0!=e>0&&this.version++,this._anisotropy=e}get clearcoat(){return this._clearcoat}set clearcoat(e){this._clearcoat>0!=e>0&&this.version++,this._clearcoat=e}get iridescence(){return this._iridescence}set iridescence(e){this._iridescence>0!=e>0&&this.version++,this._iridescence=e}get dispersion(){return this._dispersion}set dispersion(e){this._dispersion>0!=e>0&&this.version++,this._dispersion=e}get sheen(){return this._sheen}set sheen(e){this._sheen>0!=e>0&&this.version++,this._sheen=e}get transmission(){return this._transmission}set transmission(e){this._transmission>0!=e>0&&this.version++,this._transmission=e}copy(e){return super.copy(e),this.defines={STANDARD:"",PHYSICAL:""},this.anisotropy=e.anisotropy,this.anisotropyRotation=e.anisotropyRotation,this.anisotropyMap=e.anisotropyMap,this.clearcoat=e.clearcoat,this.clearcoatMap=e.clearcoatMap,this.clearcoatRoughness=e.clearcoatRoughness,this.clearcoatRoughnessMap=e.clearcoatRoughnessMap,this.clearcoatNormalMap=e.clearcoatNormalMap,this.clearcoatNormalScale.copy(e.clearcoatNormalScale),this.dispersion=e.dispersion,this.ior=e.ior,this.iridescence=e.iridescence,this.iridescenceMap=e.iridescenceMap,this.iridescenceIOR=e.iridescenceIOR,this.iridescenceThicknessRange=[...e.iridescenceThicknessRange],this.iridescenceThicknessMap=e.iridescenceThicknessMap,this.sheen=e.sheen,this.sheenColor.copy(e.sheenColor),this.sheenColorMap=e.sheenColorMap,this.sheenRoughness=e.sheenRoughness,this.sheenRoughnessMap=e.sheenRoughnessMap,this.transmission=e.transmission,this.transmissionMap=e.transmissionMap,this.thickness=e.thickness,this.thicknessMap=e.thicknessMap,this.attenuationDistance=e.attenuationDistance,this.attenuationColor.copy(e.attenuationColor),this.specularIntensity=e.specularIntensity,this.specularIntensityMap=e.specularIntensityMap,this.specularColor.copy(e.specularColor),this.specularColorMap=e.specularColorMap,this}};var fo=class extends Ii{constructor(e){super(),this.isMeshDepthMaterial=!0,this.type="MeshDepthMaterial",this.depthPacking=Nf,this.map=null,this.alphaMap=null,this.displacementMap=null,this.displacementScale=1,this.displacementBias=0,this.wireframe=!1,this.wireframeLinewidth=1,this.setValues(e)}copy(e){return super.copy(e),this.depthPacking=e.depthPacking,this.map=e.map,this.alphaMap=e.alphaMap,this.displacementMap=e.displacementMap,this.displacementScale=e.displacementScale,this.displacementBias=e.displacementBias,this.wireframe=e.wireframe,this.wireframeLinewidth=e.wireframeLinewidth,this}},po=class extends Ii{constructor(e){super(),this.isMeshDistanceMaterial=!0,this.type="MeshDistanceMaterial",this.map=null,this.alphaMap=null,this.displacementMap=null,this.displacementScale=1,this.displacementBias=0,this.setValues(e)}copy(e){return super.copy(e),this.map=e.map,this.alphaMap=e.alphaMap,this.displacementMap=e.displacementMap,this.displacementScale=e.displacementScale,this.displacementBias=e.displacementBias,this}};function ja(i,e){return!i||i.constructor===e?i:typeof e.BYTES_PER_ELEMENT=="number"?new e(i):Array.prototype.slice.call(i)}function Jm(i){return ArrayBuffer.isView(i)&&!(i instanceof DataView)}var rr=class{constructor(e,t,n,r){this.parameterPositions=e,this._cachedIndex=0,this.resultBuffer=r!==void 0?r:new t.constructor(n),this.sampleValues=t,this.valueSize=n,this.settings=null,this.DefaultSettings_={}}evaluate(e){let t=this.parameterPositions,n=this._cachedIndex,r=t[n],s=t[n-1];n:{e:{let a;t:{i:if(!(e<r)){for(let o=n+2;;){if(r===void 0){if(e<s)break i;return n=t.length,this._cachedIndex=n,this.copySampleValue_(n-1)}if(n===o)break;if(s=r,r=t[++n],e<r)break e}a=t.length;break t}if(!(e>=s)){let o=t[1];e<o&&(n=2,s=o);for(let c=n-2;;){if(s===void 0)return this._cachedIndex=0,this.copySampleValue_(0);if(n===c)break;if(r=s,s=t[--n-1],e>=s)break e}a=n,n=0;break t}break n}for(;n<a;){let o=n+a>>>1;e<t[o]?a=o:n=o+1}if(r=t[n],s=t[n-1],s===void 0)return this._cachedIndex=0,this.copySampleValue_(0);if(r===void 0)return n=t.length,this._cachedIndex=n,this.copySampleValue_(n-1)}this._cachedIndex=n,this.intervalChanged_(n,s,r)}return this.interpolate_(n,s,e,r)}getSettings_(){return this.settings||this.DefaultSettings_}copySampleValue_(e){let t=this.resultBuffer,n=this.sampleValues,r=this.valueSize,s=e*r;for(let a=0;a!==r;++a)t[a]=n[s+a];return t}interpolate_(){throw new Error("call to abstract method")}intervalChanged_(){}},mo=class extends rr{constructor(e,t,n,r){super(e,t,n,r),this._weightPrev=-0,this._offsetPrev=-0,this._weightNext=-0,this._offsetNext=-0,this.DefaultSettings_={endingStart:au,endingEnd:au}}intervalChanged_(e,t,n){let r=this.parameterPositions,s=e-2,a=e+1,o=r[s],c=r[a];if(o===void 0)switch(this.getSettings_().endingStart){case ou:s=e,o=2*t-n;break;case cu:s=r.length-2,o=t+r[s]-r[s+1];break;default:s=e,o=n}if(c===void 0)switch(this.getSettings_().endingEnd){case ou:a=e,c=2*n-t;break;case cu:a=1,c=n+r[1]-r[0];break;default:a=e-1,c=t}let u=(n-t)*.5,f=this.valueSize;this._weightPrev=u/(t-o),this._weightNext=u/(c-n),this._offsetPrev=s*f,this._offsetNext=a*f}interpolate_(e,t,n,r){let s=this.resultBuffer,a=this.sampleValues,o=this.valueSize,c=e*o,u=c-o,f=this._offsetPrev,h=this._offsetNext,l=this._weightPrev,p=this._weightNext,g=(n-t)/(r-t),b=g*g,m=b*g,d=-l*m+2*l*b-l*g,_=(1+l)*m+(-1.5-2*l)*b+(-.5+l)*g+1,y=(-1-p)*m+(1.5+p)*b+.5*g,M=p*m-p*b;for(let w=0;w!==o;++w)s[w]=d*a[f+w]+_*a[u+w]+y*a[c+w]+M*a[h+w];return s}},go=class extends rr{constructor(e,t,n,r){super(e,t,n,r)}interpolate_(e,t,n,r){let s=this.resultBuffer,a=this.sampleValues,o=this.valueSize,c=e*o,u=c-o,f=(n-t)/(r-t),h=1-f;for(let l=0;l!==o;++l)s[l]=a[u+l]*h+a[c+l]*f;return s}},xo=class extends rr{constructor(e,t,n,r){super(e,t,n,r)}interpolate_(e){return this.copySampleValue_(e-1)}},Rn=class{constructor(e,t,n,r){if(e===void 0)throw new Error("THREE.KeyframeTrack: track name is undefined");if(t===void 0||t.length===0)throw new Error("THREE.KeyframeTrack: no keyframes in track named "+e);this.name=e,this.times=ja(t,this.TimeBufferType),this.values=ja(n,this.ValueBufferType),this.setInterpolation(r||this.DefaultInterpolation)}static toJSON(e){let t=e.constructor,n;if(t.toJSON!==this.toJSON)n=t.toJSON(e);else{n={name:e.name,times:ja(e.times,Array),values:ja(e.values,Array)};let r=e.getInterpolation();r!==e.DefaultInterpolation&&(n.interpolation=r)}return n.type=e.ValueTypeName,n}InterpolantFactoryMethodDiscrete(e){return new xo(this.times,this.values,this.getValueSize(),e)}InterpolantFactoryMethodLinear(e){return new go(this.times,this.values,this.getValueSize(),e)}InterpolantFactoryMethodSmooth(e){return new mo(this.times,this.values,this.getValueSize(),e)}setInterpolation(e){let t;switch(e){case Ls:t=this.InterpolantFactoryMethodDiscrete;break;case so:t=this.InterpolantFactoryMethodLinear;break;case to:t=this.InterpolantFactoryMethodSmooth;break}if(t===void 0){let n="unsupported interpolation for "+this.ValueTypeName+" keyframe track named "+this.name;if(this.createInterpolant===void 0)if(e!==this.DefaultInterpolation)this.setInterpolation(this.DefaultInterpolation);else throw new Error(n);return Ze("KeyframeTrack:",n),this}return this.createInterpolant=t,this}getInterpolation(){switch(this.createInterpolant){case this.InterpolantFactoryMethodDiscrete:return Ls;case this.InterpolantFactoryMethodLinear:return so;case this.InterpolantFactoryMethodSmooth:return to}}getValueSize(){return this.values.length/this.times.length}shift(e){if(e!==0){let t=this.times;for(let n=0,r=t.length;n!==r;++n)t[n]+=e}return this}scale(e){if(e!==1){let t=this.times;for(let n=0,r=t.length;n!==r;++n)t[n]*=e}return this}trim(e,t){let n=this.times,r=n.length,s=0,a=r-1;for(;s!==r&&n[s]<e;)++s;for(;a!==-1&&n[a]>t;)--a;if(++a,s!==0||a!==r){s>=a&&(a=Math.max(a,1),s=a-1);let o=this.getValueSize();this.times=n.slice(s,a),this.values=this.values.slice(s*o,a*o)}return this}validate(){let e=!0,t=this.getValueSize();t-Math.floor(t)!==0&&(ut("KeyframeTrack: Invalid value size in track.",this),e=!1);let n=this.times,r=this.values,s=n.length;s===0&&(ut("KeyframeTrack: Track is empty.",this),e=!1);let a=null;for(let o=0;o!==s;o++){let c=n[o];if(typeof c=="number"&&isNaN(c)){ut("KeyframeTrack: Time is not a valid number.",this,o,c),e=!1;break}if(a!==null&&a>c){ut("KeyframeTrack: Out of order keys.",this,o,c,a),e=!1;break}a=c}if(r!==void 0&&Jm(r))for(let o=0,c=r.length;o!==c;++o){let u=r[o];if(isNaN(u)){ut("KeyframeTrack: Value is not a valid number.",this,o,u),e=!1;break}}return e}optimize(){let e=this.times.slice(),t=this.values.slice(),n=this.getValueSize(),r=this.getInterpolation()===to,s=e.length-1,a=1;for(let o=1;o<s;++o){let c=!1,u=e[o],f=e[o+1];if(u!==f&&(o!==1||u!==e[0]))if(r)c=!0;else{let h=o*n,l=h-n,p=h+n;for(let g=0;g!==n;++g){let b=t[h+g];if(b!==t[l+g]||b!==t[p+g]){c=!0;break}}}if(c){if(o!==a){e[a]=e[o];let h=o*n,l=a*n;for(let p=0;p!==n;++p)t[l+p]=t[h+p]}++a}}if(s>0){e[a]=e[s];for(let o=s*n,c=a*n,u=0;u!==n;++u)t[c+u]=t[o+u];++a}return a!==e.length?(this.times=e.slice(0,a),this.values=t.slice(0,a*n)):(this.times=e,this.values=t),this}clone(){let e=this.times.slice(),t=this.values.slice(),n=this.constructor,r=new n(this.name,e,t);return r.createInterpolant=this.createInterpolant,r}};Rn.prototype.ValueTypeName="";Rn.prototype.TimeBufferType=Float32Array;Rn.prototype.ValueBufferType=Float32Array;Rn.prototype.DefaultInterpolation=so;var Pi=class extends Rn{constructor(e,t,n){super(e,t,n)}};Pi.prototype.ValueTypeName="bool";Pi.prototype.ValueBufferType=Array;Pi.prototype.DefaultInterpolation=Ls;Pi.prototype.InterpolantFactoryMethodLinear=void 0;Pi.prototype.InterpolantFactoryMethodSmooth=void 0;var vo=class extends Rn{constructor(e,t,n,r){super(e,t,n,r)}};vo.prototype.ValueTypeName="color";var _o=class extends Rn{constructor(e,t,n,r){super(e,t,n,r)}};_o.prototype.ValueTypeName="number";var yo=class extends rr{constructor(e,t,n,r){super(e,t,n,r)}interpolate_(e,t,n,r){let s=this.resultBuffer,a=this.sampleValues,o=this.valueSize,c=(n-t)/(r-t),u=e*o;for(let f=u+o;u!==f;u+=4)Wn.slerpFlat(s,0,a,u-o,a,u,c);return s}},Ys=class extends Rn{constructor(e,t,n,r){super(e,t,n,r)}InterpolantFactoryMethodLinear(e){return new yo(this.times,this.values,this.getValueSize(),e)}};Ys.prototype.ValueTypeName="quaternion";Ys.prototype.InterpolantFactoryMethodSmooth=void 0;var Di=class extends Rn{constructor(e,t,n){super(e,t,n)}};Di.prototype.ValueTypeName="string";Di.prototype.ValueBufferType=Array;Di.prototype.DefaultInterpolation=Ls;Di.prototype.InterpolantFactoryMethodLinear=void 0;Di.prototype.InterpolantFactoryMethodSmooth=void 0;var bo=class extends Rn{constructor(e,t,n,r){super(e,t,n,r)}};bo.prototype.ValueTypeName="vector";var zr={enabled:!1,files:{},add:function(i,e){this.enabled!==!1&&(this.files[i]=e)},get:function(i){if(this.enabled!==!1)return this.files[i]},remove:function(i){delete this.files[i]},clear:function(){this.files={}}},So=class{constructor(e,t,n){let r=this,s=!1,a=0,o=0,c,u=[];this.onStart=void 0,this.onLoad=e,this.onProgress=t,this.onError=n,this._abortController=null,this.itemStart=function(f){o++,s===!1&&r.onStart!==void 0&&r.onStart(f,a,o),s=!0},this.itemEnd=function(f){a++,r.onProgress!==void 0&&r.onProgress(f,a,o),a===o&&(s=!1,r.onLoad!==void 0&&r.onLoad())},this.itemError=function(f){r.onError!==void 0&&r.onError(f)},this.resolveURL=function(f){return c?c(f):f},this.setURLModifier=function(f){return c=f,this},this.addHandler=function(f,h){return u.push(f,h),this},this.removeHandler=function(f){let h=u.indexOf(f);return h!==-1&&u.splice(h,2),this},this.getHandler=function(f){for(let h=0,l=u.length;h<l;h+=2){let p=u[h],g=u[h+1];if(p.global&&(p.lastIndex=0),p.test(f))return g}return null},this.abort=function(){return this.abortController.abort(),this._abortController=null,this}}get abortController(){return this._abortController||(this._abortController=new AbortController),this._abortController}},$f=new So,Fi=class{constructor(e){this.manager=e!==void 0?e:$f,this.crossOrigin="anonymous",this.withCredentials=!1,this.path="",this.resourcePath="",this.requestHeader={}}load(){}loadAsync(e,t){let n=this;return new Promise(function(r,s){n.load(e,r,t,s)})}parse(){}setCrossOrigin(e){return this.crossOrigin=e,this}setWithCredentials(e){return this.withCredentials=e,this}setPath(e){return this.path=e,this}setResourcePath(e){return this.resourcePath=e,this}setRequestHeader(e){return this.requestHeader=e,this}abort(){return this}};Fi.DEFAULT_MATERIAL_NAME="__DEFAULT";var ui={},hu=class extends Error{constructor(e,t){super(e),this.response=t}},Mo=class extends Fi{constructor(e){super(e),this.mimeType="",this.responseType="",this._abortController=new AbortController}load(e,t,n,r){e===void 0&&(e=""),this.path!==void 0&&(e=this.path+e),e=this.manager.resolveURL(e);let s=zr.get(`file:${e}`);if(s!==void 0)return this.manager.itemStart(e),setTimeout(()=>{t&&t(s),this.manager.itemEnd(e)},0),s;if(ui[e]!==void 0){ui[e].push({onLoad:t,onProgress:n,onError:r});return}ui[e]=[],ui[e].push({onLoad:t,onProgress:n,onError:r});let a=new Request(e,{headers:new Headers(this.requestHeader),credentials:this.withCredentials?"include":"same-origin",signal:typeof AbortSignal.any=="function"?AbortSignal.any([this._abortController.signal,this.manager.abortController.signal]):this._abortController.signal}),o=this.mimeType,c=this.responseType;fetch(a).then(u=>{if(u.status===200||u.status===0){if(u.status===0&&Ze("FileLoader: HTTP Status 0 received."),typeof ReadableStream>"u"||u.body===void 0||u.body.getReader===void 0)return u;let f=ui[e],h=u.body.getReader(),l=u.headers.get("X-File-Size")||u.headers.get("Content-Length"),p=l?parseInt(l):0,g=p!==0,b=0,m=new ReadableStream({start(d){_();function _(){h.read().then(({done:y,value:M})=>{if(y)d.close();else{b+=M.byteLength;let w=new ProgressEvent("progress",{lengthComputable:g,loaded:b,total:p});for(let A=0,I=f.length;A<I;A++){let D=f[A];D.onProgress&&D.onProgress(w)}d.enqueue(M),_()}},y=>{d.error(y)})}}});return new Response(m)}else throw new hu(`fetch for "${u.url}" responded with ${u.status}: ${u.statusText}`,u)}).then(u=>{switch(c){case"arraybuffer":return u.arrayBuffer();case"blob":return u.blob();case"document":return u.text().then(f=>new DOMParser().parseFromString(f,o));case"json":return u.json();default:if(o==="")return u.text();{let h=/charset="?([^;"\s]*)"?/i.exec(o),l=h&&h[1]?h[1].toLowerCase():void 0,p=new TextDecoder(l);return u.arrayBuffer().then(g=>p.decode(g))}}}).then(u=>{zr.add(`file:${e}`,u);let f=ui[e];delete ui[e];for(let h=0,l=f.length;h<l;h++){let p=f[h];p.onLoad&&p.onLoad(u)}}).catch(u=>{let f=ui[e];if(f===void 0)throw this.manager.itemError(e),u;delete ui[e];for(let h=0,l=f.length;h<l;h++){let p=f[h];p.onError&&p.onError(u)}this.manager.itemError(e)}).finally(()=>{this.manager.itemEnd(e)}),this.manager.itemStart(e)}setResponseType(e){return this.responseType=e,this}setMimeType(e){return this.mimeType=e,this}abort(){return this._abortController.abort(),this._abortController=new AbortController,this}};var Nr=new WeakMap,To=class extends Fi{constructor(e){super(e)}load(e,t,n,r){this.path!==void 0&&(e=this.path+e),e=this.manager.resolveURL(e);let s=this,a=zr.get(`image:${e}`);if(a!==void 0){if(a.complete===!0)s.manager.itemStart(e),setTimeout(function(){t&&t(a),s.manager.itemEnd(e)},0);else{let h=Nr.get(a);h===void 0&&(h=[],Nr.set(a,h)),h.push({onLoad:t,onError:r})}return a}let o=Vr("img");function c(){f(),t&&t(this);let h=Nr.get(this)||[];for(let l=0;l<h.length;l++){let p=h[l];p.onLoad&&p.onLoad(this)}Nr.delete(this),s.manager.itemEnd(e)}function u(h){f(),r&&r(h),zr.remove(`image:${e}`);let l=Nr.get(this)||[];for(let p=0;p<l.length;p++){let g=l[p];g.onError&&g.onError(h)}Nr.delete(this),s.manager.itemError(e),s.manager.itemEnd(e)}function f(){o.removeEventListener("load",c,!1),o.removeEventListener("error",u,!1)}return o.addEventListener("load",c,!1),o.addEventListener("error",u,!1),e.slice(0,5)!=="data:"&&this.crossOrigin!==void 0&&(o.crossOrigin=this.crossOrigin),zr.add(`image:${e}`,o),s.manager.itemStart(e),o.src=e,o}};var sr=class extends Fi{constructor(e){super(e)}load(e,t,n,r){let s=this,a=new St,o=new Mo(this.manager);return o.setResponseType("arraybuffer"),o.setRequestHeader(this.requestHeader),o.setPath(this.path),o.setWithCredentials(s.withCredentials),o.load(e,function(c){let u;try{u=s.parse(c)}catch(f){if(r!==void 0)r(f);else{f(f);return}}u.image!==void 0?a.image=u.image:u.data!==void 0&&(a.image.width=u.width,a.image.height=u.height,a.image.data=u.data),a.wrapS=u.wrapS!==void 0?u.wrapS:Lt,a.wrapT=u.wrapT!==void 0?u.wrapT:Lt,a.magFilter=u.magFilter!==void 0?u.magFilter:ft,a.minFilter=u.minFilter!==void 0?u.minFilter:ft,a.anisotropy=u.anisotropy!==void 0?u.anisotropy:1,u.colorSpace!==void 0&&(a.colorSpace=u.colorSpace),u.flipY!==void 0&&(a.flipY=u.flipY),u.format!==void 0&&(a.format=u.format),u.type!==void 0&&(a.type=u.type),u.mipmaps!==void 0&&(a.mipmaps=u.mipmaps,a.minFilter=mi),u.mipmapCount===1&&(a.minFilter=ft),u.generateMipmaps!==void 0&&(a.generateMipmaps=u.generateMipmaps),a.needsUpdate=!0,t&&t(a,u)},n,r),a}},Zs=class extends Fi{constructor(e){super(e)}load(e,t,n,r){let s=new mn,a=new To(this.manager);return a.setCrossOrigin(this.crossOrigin),a.setPath(this.path),a.load(e,function(o){s.image=o,s.needsUpdate=!0,t!==void 0&&t(s)},n,r),s}},$r=class extends nn{constructor(e,t=1){super(),this.isLight=!0,this.type="Light",this.color=new Ye(e),this.intensity=t}dispose(){}copy(e,t){return super.copy(e,t),this.color.copy(e.color),this.intensity=e.intensity,this}toJSON(e){let t=super.toJSON(e);return t.object.color=this.color.getHex(),t.object.intensity=this.intensity,this.groundColor!==void 0&&(t.object.groundColor=this.groundColor.getHex()),this.distance!==void 0&&(t.object.distance=this.distance),this.angle!==void 0&&(t.object.angle=this.angle),this.decay!==void 0&&(t.object.decay=this.decay),this.penumbra!==void 0&&(t.object.penumbra=this.penumbra),this.shadow!==void 0&&(t.object.shadow=this.shadow.toJSON()),this.target!==void 0&&(t.object.target=this.target.uuid),t}};var iu=new Xe,ef=new k,tf=new k,$s=class{constructor(e){this.camera=e,this.intensity=1,this.bias=0,this.normalBias=0,this.radius=1,this.blurSamples=8,this.mapSize=new Le(512,512),this.mapType=dn,this.map=null,this.mapPass=null,this.matrix=new Xe,this.autoUpdate=!0,this.needsUpdate=!1,this._frustum=new Zr,this._frameExtents=new Le(1,1),this._viewportCount=1,this._viewports=[new ht(0,0,1,1)]}getViewportCount(){return this._viewportCount}getFrustum(){return this._frustum}updateMatrices(e){let t=this.camera,n=this.matrix;ef.setFromMatrixPosition(e.matrixWorld),t.position.copy(ef),tf.setFromMatrixPosition(e.target.matrixWorld),t.lookAt(tf),t.updateMatrixWorld(),iu.multiplyMatrices(t.projectionMatrix,t.matrixWorldInverse),this._frustum.setFromProjectionMatrix(iu,t.coordinateSystem,t.reversedDepth),t.reversedDepth?n.set(.5,0,0,.5,0,.5,0,.5,0,0,1,0,0,0,0,1):n.set(.5,0,0,.5,0,.5,0,.5,0,0,.5,.5,0,0,0,1),n.multiply(iu)}getViewport(e){return this._viewports[e]}getFrameExtents(){return this._frameExtents}dispose(){this.map&&this.map.dispose(),this.mapPass&&this.mapPass.dispose()}copy(e){return this.camera=e.camera.clone(),this.intensity=e.intensity,this.bias=e.bias,this.radius=e.radius,this.autoUpdate=e.autoUpdate,this.needsUpdate=e.needsUpdate,this.normalBias=e.normalBias,this.blurSamples=e.blurSamples,this.mapSize.copy(e.mapSize),this}clone(){return new this.constructor().copy(this)}toJSON(){let e={};return this.intensity!==1&&(e.intensity=this.intensity),this.bias!==0&&(e.bias=this.bias),this.normalBias!==0&&(e.normalBias=this.normalBias),this.radius!==1&&(e.radius=this.radius),(this.mapSize.x!==512||this.mapSize.y!==512)&&(e.mapSize=this.mapSize.toArray()),e.camera=this.camera.toJSON(!1).object,delete e.camera.matrix,e}},fu=class extends $s{constructor(){super(new kt(50,1,.5,500)),this.isSpotLightShadow=!0,this.focus=1,this.aspect=1}updateMatrices(e){let t=this.camera,n=Bs*2*e.angle*this.focus,r=this.mapSize.width/this.mapSize.height*this.aspect,s=e.distance||t.far;(n!==t.fov||r!==t.aspect||s!==t.far)&&(t.fov=n,t.aspect=r,t.far=s,t.updateProjectionMatrix()),super.updateMatrices(e)}copy(e){return super.copy(e),this.focus=e.focus,this}},Js=class extends $r{constructor(e,t,n=0,r=Math.PI/3,s=0,a=2){super(e,t),this.isSpotLight=!0,this.type="SpotLight",this.position.copy(nn.DEFAULT_UP),this.updateMatrix(),this.target=new nn,this.distance=n,this.angle=r,this.penumbra=s,this.decay=a,this.map=null,this.shadow=new fu}get power(){return this.intensity*Math.PI}set power(e){this.intensity=e/Math.PI}dispose(){this.shadow.dispose()}copy(e,t){return super.copy(e,t),this.distance=e.distance,this.angle=e.angle,this.penumbra=e.penumbra,this.decay=e.decay,this.target=e.target.clone(),this.shadow=e.shadow.clone(),this}},nf=new Xe,Fs=new k,ru=new k,du=class extends $s{constructor(){super(new kt(90,1,.5,500)),this.isPointLightShadow=!0,this._frameExtents=new Le(4,2),this._viewportCount=6,this._viewports=[new ht(2,1,1,1),new ht(0,1,1,1),new ht(3,1,1,1),new ht(1,1,1,1),new ht(3,0,1,1),new ht(1,0,1,1)],this._cubeDirections=[new k(1,0,0),new k(-1,0,0),new k(0,0,1),new k(0,0,-1),new k(0,1,0),new k(0,-1,0)],this._cubeUps=[new k(0,1,0),new k(0,1,0),new k(0,1,0),new k(0,1,0),new k(0,0,1),new k(0,0,-1)]}updateMatrices(e,t=0){let n=this.camera,r=this.matrix,s=e.distance||n.far;s!==n.far&&(n.far=s,n.updateProjectionMatrix()),Fs.setFromMatrixPosition(e.matrixWorld),n.position.copy(Fs),ru.copy(n.position),ru.add(this._cubeDirections[t]),n.up.copy(this._cubeUps[t]),n.lookAt(ru),n.updateMatrixWorld(),r.makeTranslation(-Fs.x,-Fs.y,-Fs.z),nf.multiplyMatrices(n.projectionMatrix,n.matrixWorldInverse),this._frustum.setFromProjectionMatrix(nf,n.coordinateSystem,n.reversedDepth)}},Ks=class extends $r{constructor(e,t,n=0,r=2){super(e,t),this.isPointLight=!0,this.type="PointLight",this.distance=n,this.decay=r,this.shadow=new du}get power(){return this.intensity*4*Math.PI}set power(e){this.intensity=e/(4*Math.PI)}dispose(){this.shadow.dispose()}copy(e,t){return super.copy(e,t),this.distance=e.distance,this.decay=e.decay,this.shadow=e.shadow.clone(),this}},pi=class extends Vs{constructor(e=-1,t=1,n=1,r=-1,s=.1,a=2e3){super(),this.isOrthographicCamera=!0,this.type="OrthographicCamera",this.zoom=1,this.view=null,this.left=e,this.right=t,this.top=n,this.bottom=r,this.near=s,this.far=a,this.updateProjectionMatrix()}copy(e,t){return super.copy(e,t),this.left=e.left,this.right=e.right,this.top=e.top,this.bottom=e.bottom,this.near=e.near,this.far=e.far,this.zoom=e.zoom,this.view=e.view===null?null:Object.assign({},e.view),this}setViewOffset(e,t,n,r,s,a){this.view===null&&(this.view={enabled:!0,fullWidth:1,fullHeight:1,offsetX:0,offsetY:0,width:1,height:1}),this.view.enabled=!0,this.view.fullWidth=e,this.view.fullHeight=t,this.view.offsetX=n,this.view.offsetY=r,this.view.width=s,this.view.height=a,this.updateProjectionMatrix()}clearViewOffset(){this.view!==null&&(this.view.enabled=!1),this.updateProjectionMatrix()}updateProjectionMatrix(){let e=(this.right-this.left)/(2*this.zoom),t=(this.top-this.bottom)/(2*this.zoom),n=(this.right+this.left)/2,r=(this.top+this.bottom)/2,s=n-e,a=n+e,o=r+t,c=r-t;if(this.view!==null&&this.view.enabled){let u=(this.right-this.left)/this.view.fullWidth/this.zoom,f=(this.top-this.bottom)/this.view.fullHeight/this.zoom;s+=u*this.view.offsetX,a=s+u*this.view.width,o-=f*this.view.offsetY,c=o-f*this.view.height}this.projectionMatrix.makeOrthographic(s,a,o,c,this.near,this.far,this.coordinateSystem,this.reversedDepth),this.projectionMatrixInverse.copy(this.projectionMatrix).invert()}toJSON(e){let t=super.toJSON(e);return t.object.zoom=this.zoom,t.object.left=this.left,t.object.right=this.right,t.object.top=this.top,t.object.bottom=this.bottom,t.object.near=this.near,t.object.far=this.far,this.view!==null&&(t.object.view=Object.assign({},this.view)),t}},pu=class extends $s{constructor(){super(new pi(-5,5,5,-5,.5,500)),this.isDirectionalLightShadow=!0}},Qs=class extends $r{constructor(e,t){super(e,t),this.isDirectionalLight=!0,this.type="DirectionalLight",this.position.copy(nn.DEFAULT_UP),this.updateMatrix(),this.target=new nn,this.shadow=new pu}dispose(){this.shadow.dispose()}copy(e){return super.copy(e),this.target=e.target.clone(),this.shadow=e.shadow.clone(),this}};var wo=class extends kt{constructor(e=[]){super(),this.isArrayCamera=!0,this.isMultiViewCamera=!1,this.cameras=e}},js=class{constructor(e=!0){this.autoStart=e,this.startTime=0,this.oldTime=0,this.elapsedTime=0,this.running=!1}start(){this.startTime=performance.now(),this.oldTime=this.startTime,this.elapsedTime=0,this.running=!0}stop(){this.getElapsedTime(),this.running=!1,this.autoStart=!1}getElapsedTime(){return this.getDelta(),this.elapsedTime}getDelta(){let e=0;if(this.autoStart&&!this.running)return this.start(),0;if(this.running){let t=performance.now();e=(t-this.oldTime)/1e3,this.oldTime=t,this.elapsedTime+=e}return e}};var Fu="\\[\\]\\.:\\/",Km=new RegExp("["+Fu+"]","g"),Lu="[^"+Fu+"]",Qm="[^"+Fu.replace("\\.","")+"]",jm=/((?:WC+[\/:])*)/.source.replace("WC",Lu),e0=/(WCOD+)?/.source.replace("WCOD",Qm),t0=/(?:\.(WC+)(?:\[(.+)\])?)?/.source.replace("WC",Lu),n0=/\.(WC+)(?:\[(.+)\])?/.source.replace("WC",Lu),i0=new RegExp("^"+jm+e0+t0+n0+"$"),r0=["material","materials","bones","map"],mu=class{constructor(e,t,n){let r=n||Ft.parseTrackName(t);this._targetGroup=e,this._bindings=e.subscribe_(t,r)}getValue(e,t){this.bind();let n=this._targetGroup.nCachedObjects_,r=this._bindings[n];r!==void 0&&r.getValue(e,t)}setValue(e,t){let n=this._bindings;for(let r=this._targetGroup.nCachedObjects_,s=n.length;r!==s;++r)n[r].setValue(e,t)}bind(){let e=this._bindings;for(let t=this._targetGroup.nCachedObjects_,n=e.length;t!==n;++t)e[t].bind()}unbind(){let e=this._bindings;for(let t=this._targetGroup.nCachedObjects_,n=e.length;t!==n;++t)e[t].unbind()}},Ft=class i{constructor(e,t,n){this.path=t,this.parsedPath=n||i.parseTrackName(t),this.node=i.findNode(e,this.parsedPath.nodeName),this.rootNode=e,this.getValue=this._getValue_unbound,this.setValue=this._setValue_unbound}static create(e,t,n){return e&&e.isAnimationObjectGroup?new i.Composite(e,t,n):new i(e,t,n)}static sanitizeNodeName(e){return e.replace(/\s/g,"_").replace(Km,"")}static parseTrackName(e){let t=i0.exec(e);if(t===null)throw new Error("PropertyBinding: Cannot parse trackName: "+e);let n={nodeName:t[2],objectName:t[3],objectIndex:t[4],propertyName:t[5],propertyIndex:t[6]},r=n.nodeName&&n.nodeName.lastIndexOf(".");if(r!==void 0&&r!==-1){let s=n.nodeName.substring(r+1);r0.indexOf(s)!==-1&&(n.nodeName=n.nodeName.substring(0,r),n.objectName=s)}if(n.propertyName===null||n.propertyName.length===0)throw new Error("PropertyBinding: can not parse propertyName from trackName: "+e);return n}static findNode(e,t){if(t===void 0||t===""||t==="."||t===-1||t===e.name||t===e.uuid)return e;if(e.skeleton){let n=e.skeleton.getBoneByName(t);if(n!==void 0)return n}if(e.children){let n=function(s){for(let a=0;a<s.length;a++){let o=s[a];if(o.name===t||o.uuid===t)return o;let c=n(o.children);if(c)return c}return null},r=n(e.children);if(r)return r}return null}_getValue_unavailable(){}_setValue_unavailable(){}_getValue_direct(e,t){e[t]=this.targetObject[this.propertyName]}_getValue_array(e,t){let n=this.resolvedProperty;for(let r=0,s=n.length;r!==s;++r)e[t++]=n[r]}_getValue_arrayElement(e,t){e[t]=this.resolvedProperty[this.propertyIndex]}_getValue_toArray(e,t){this.resolvedProperty.toArray(e,t)}_setValue_direct(e,t){this.targetObject[this.propertyName]=e[t]}_setValue_direct_setNeedsUpdate(e,t){this.targetObject[this.propertyName]=e[t],this.targetObject.needsUpdate=!0}_setValue_direct_setMatrixWorldNeedsUpdate(e,t){this.targetObject[this.propertyName]=e[t],this.targetObject.matrixWorldNeedsUpdate=!0}_setValue_array(e,t){let n=this.resolvedProperty;for(let r=0,s=n.length;r!==s;++r)n[r]=e[t++]}_setValue_array_setNeedsUpdate(e,t){let n=this.resolvedProperty;for(let r=0,s=n.length;r!==s;++r)n[r]=e[t++];this.targetObject.needsUpdate=!0}_setValue_array_setMatrixWorldNeedsUpdate(e,t){let n=this.resolvedProperty;for(let r=0,s=n.length;r!==s;++r)n[r]=e[t++];this.targetObject.matrixWorldNeedsUpdate=!0}_setValue_arrayElement(e,t){this.resolvedProperty[this.propertyIndex]=e[t]}_setValue_arrayElement_setNeedsUpdate(e,t){this.resolvedProperty[this.propertyIndex]=e[t],this.targetObject.needsUpdate=!0}_setValue_arrayElement_setMatrixWorldNeedsUpdate(e,t){this.resolvedProperty[this.propertyIndex]=e[t],this.targetObject.matrixWorldNeedsUpdate=!0}_setValue_fromArray(e,t){this.resolvedProperty.fromArray(e,t)}_setValue_fromArray_setNeedsUpdate(e,t){this.resolvedProperty.fromArray(e,t),this.targetObject.needsUpdate=!0}_setValue_fromArray_setMatrixWorldNeedsUpdate(e,t){this.resolvedProperty.fromArray(e,t),this.targetObject.matrixWorldNeedsUpdate=!0}_getValue_unbound(e,t){this.bind(),this.getValue(e,t)}_setValue_unbound(e,t){this.bind(),this.setValue(e,t)}bind(){let e=this.node,t=this.parsedPath,n=t.objectName,r=t.propertyName,s=t.propertyIndex;if(e||(e=i.findNode(this.rootNode,t.nodeName),this.node=e),this.getValue=this._getValue_unavailable,this.setValue=this._setValue_unavailable,!e){Ze("PropertyBinding: No target node found for track: "+this.path+".");return}if(n){let u=t.objectIndex;switch(n){case"materials":if(!e.material){ut("PropertyBinding: Can not bind to material as node does not have a material.",this);return}if(!e.material.materials){ut("PropertyBinding: Can not bind to material.materials as node.material does not have a materials array.",this);return}e=e.material.materials;break;case"bones":if(!e.skeleton){ut("PropertyBinding: Can not bind to bones as node does not have a skeleton.",this);return}e=e.skeleton.bones;for(let f=0;f<e.length;f++)if(e[f].name===u){u=f;break}break;case"map":if("map"in e){e=e.map;break}if(!e.material){ut("PropertyBinding: Can not bind to material as node does not have a material.",this);return}if(!e.material.map){ut("PropertyBinding: Can not bind to material.map as node.material does not have a map.",this);return}e=e.material.map;break;default:if(e[n]===void 0){ut("PropertyBinding: Can not bind to objectName of node undefined.",this);return}e=e[n]}if(u!==void 0){if(e[u]===void 0){ut("PropertyBinding: Trying to bind to objectIndex of objectName, but is undefined.",this,e);return}e=e[u]}}let a=e[r];if(a===void 0){let u=t.nodeName;ut("PropertyBinding: Trying to update property for track: "+u+"."+r+" but it wasn't found.",e);return}let o=this.Versioning.None;this.targetObject=e,e.isMaterial===!0?o=this.Versioning.NeedsUpdate:e.isObject3D===!0&&(o=this.Versioning.MatrixWorldNeedsUpdate);let c=this.BindingType.Direct;if(s!==void 0){if(r==="morphTargetInfluences"){if(!e.geometry){ut("PropertyBinding: Can not bind to morphTargetInfluences because node does not have a geometry.",this);return}if(!e.geometry.morphAttributes){ut("PropertyBinding: Can not bind to morphTargetInfluences because node does not have a geometry.morphAttributes.",this);return}e.morphTargetDictionary[s]!==void 0&&(s=e.morphTargetDictionary[s])}c=this.BindingType.ArrayElement,this.resolvedProperty=a,this.propertyIndex=s}else a.fromArray!==void 0&&a.toArray!==void 0?(c=this.BindingType.HasFromToArray,this.resolvedProperty=a):Array.isArray(a)?(c=this.BindingType.EntireArray,this.resolvedProperty=a):this.propertyName=r;this.getValue=this.GetterByBindingType[c],this.setValue=this.SetterByBindingTypeAndVersioning[c][o]}unbind(){this.node=null,this.getValue=this._getValue_unbound,this.setValue=this._setValue_unbound}};Ft.Composite=mu;Ft.prototype.BindingType={Direct:0,EntireArray:1,ArrayElement:2,HasFromToArray:3};Ft.prototype.Versioning={None:0,NeedsUpdate:1,MatrixWorldNeedsUpdate:2};Ft.prototype.GetterByBindingType=[Ft.prototype._getValue_direct,Ft.prototype._getValue_array,Ft.prototype._getValue_arrayElement,Ft.prototype._getValue_toArray];Ft.prototype.SetterByBindingTypeAndVersioning=[[Ft.prototype._setValue_direct,Ft.prototype._setValue_direct_setNeedsUpdate,Ft.prototype._setValue_direct_setMatrixWorldNeedsUpdate],[Ft.prototype._setValue_array,Ft.prototype._setValue_array_setNeedsUpdate,Ft.prototype._setValue_array_setMatrixWorldNeedsUpdate],[Ft.prototype._setValue_arrayElement,Ft.prototype._setValue_arrayElement_setNeedsUpdate,Ft.prototype._setValue_arrayElement_setMatrixWorldNeedsUpdate],[Ft.prototype._setValue_fromArray,Ft.prototype._setValue_fromArray_setNeedsUpdate,Ft.prototype._setValue_fromArray_setMatrixWorldNeedsUpdate]];var fb=new Float32Array(1);var ea=class{constructor(e=1,t=0,n=0){this.radius=e,this.phi=t,this.theta=n}set(e,t,n){return this.radius=e,this.phi=t,this.theta=n,this}copy(e){return this.radius=e.radius,this.phi=e.phi,this.theta=e.theta,this}makeSafe(){return this.phi=Ke(this.phi,1e-6,Math.PI-1e-6),this}setFromVector3(e){return this.setFromCartesianCoords(e.x,e.y,e.z)}setFromCartesianCoords(e,t,n){return this.radius=Math.sqrt(e*e+t*t+n*n),this.radius===0?(this.theta=0,this.phi=0):(this.theta=Math.atan2(e,n),this.phi=Math.acos(Ke(t/this.radius,-1,1))),this}clone(){return new this.constructor().copy(this)}};var rf=new k,eo=new k,Ur=new k,Br=new k,su=new k,s0=new k,a0=new k,gn=class{constructor(e=new k,t=new k){this.start=e,this.end=t}set(e,t){return this.start.copy(e),this.end.copy(t),this}copy(e){return this.start.copy(e.start),this.end.copy(e.end),this}getCenter(e){return e.addVectors(this.start,this.end).multiplyScalar(.5)}delta(e){return e.subVectors(this.end,this.start)}distanceSq(){return this.start.distanceToSquared(this.end)}distance(){return this.start.distanceTo(this.end)}at(e,t){return this.delta(t).multiplyScalar(e).add(this.start)}closestPointToPointParameter(e,t){rf.subVectors(e,this.start),eo.subVectors(this.end,this.start);let n=eo.dot(eo),s=eo.dot(rf)/n;return t&&(s=Ke(s,0,1)),s}closestPointToPoint(e,t,n){let r=this.closestPointToPointParameter(e,t);return this.delta(n).multiplyScalar(r).add(this.start)}distanceSqToLine3(e,t=s0,n=a0){let r=10000000000000001e-32,s,a,o=this.start,c=e.start,u=this.end,f=e.end;Ur.subVectors(u,o),Br.subVectors(f,c),su.subVectors(o,c);let h=Ur.dot(Ur),l=Br.dot(Br),p=Br.dot(su);if(h<=r&&l<=r)return t.copy(o),n.copy(c),t.sub(n),t.dot(t);if(h<=r)s=0,a=p/l,a=Ke(a,0,1);else{let g=Ur.dot(su);if(l<=r)a=0,s=Ke(-g/h,0,1);else{let b=Ur.dot(Br),m=h*l-b*b;m!==0?s=Ke((b*p-g*l)/m,0,1):s=0,a=(b*s+p)/l,a<0?(a=0,s=Ke(-g/h,0,1)):a>1&&(a=1,s=Ke((b-g)/h,0,1))}}return t.copy(o).add(Ur.multiplyScalar(s)),n.copy(c).add(Br.multiplyScalar(a)),t.sub(n),t.dot(t)}applyMatrix4(e){return this.start.applyMatrix4(e),this.end.applyMatrix4(e),this}equals(e){return e.start.equals(this.start)&&e.end.equals(this.end)}clone(){return new this.constructor().copy(this)}};function Nu(i,e,t,n){let r=o0(n);switch(t){case wu:return i*e;case vn:return i*e/r.components*r.byteLength;case jr:return i*e/r.components*r.byteLength;case Tn:return i*e*2/r.components*r.byteLength;case Ui:return i*e*2/r.components*r.byteLength;case Au:return i*e*3/r.components*r.byteLength;case He:return i*e*4/r.components*r.byteLength;case Bi:return i*e*4/r.components*r.byteLength;case sa:case aa:return Math.floor((i+3)/4)*Math.floor((e+3)/4)*8;case oa:case ca:return Math.floor((i+3)/4)*Math.floor((e+3)/4)*16;case zo:case Vo:return Math.max(i,16)*Math.max(e,8)/4;case Oo:case ko:return Math.max(i,8)*Math.max(e,8)/2;case Ho:case Go:return Math.floor((i+3)/4)*Math.floor((e+3)/4)*8;case Wo:return Math.floor((i+3)/4)*Math.floor((e+3)/4)*16;case Xo:return Math.floor((i+3)/4)*Math.floor((e+3)/4)*16;case qo:return Math.floor((i+4)/5)*Math.floor((e+3)/4)*16;case Yo:return Math.floor((i+4)/5)*Math.floor((e+4)/5)*16;case Zo:return Math.floor((i+5)/6)*Math.floor((e+4)/5)*16;case $o:return Math.floor((i+5)/6)*Math.floor((e+5)/6)*16;case Jo:return Math.floor((i+7)/8)*Math.floor((e+4)/5)*16;case Ko:return Math.floor((i+7)/8)*Math.floor((e+5)/6)*16;case Qo:return Math.floor((i+7)/8)*Math.floor((e+7)/8)*16;case jo:return Math.floor((i+9)/10)*Math.floor((e+4)/5)*16;case ec:return Math.floor((i+9)/10)*Math.floor((e+5)/6)*16;case tc:return Math.floor((i+9)/10)*Math.floor((e+7)/8)*16;case nc:return Math.floor((i+9)/10)*Math.floor((e+9)/10)*16;case ic:return Math.floor((i+11)/12)*Math.floor((e+9)/10)*16;case rc:return Math.floor((i+11)/12)*Math.floor((e+11)/12)*16;case sc:case ac:case oc:return Math.ceil(i/4)*Math.ceil(e/4)*16;case cc:case lc:return Math.ceil(i/4)*Math.ceil(e/4)*8;case uc:case hc:return Math.ceil(i/4)*Math.ceil(e/4)*16}throw new Error(`Unable to determine texture byte length for ${t} format.`)}function o0(i){switch(i){case dn:case Jr:return{byteLength:1,components:1};case Li:case ra:case _t:return{byteLength:2,components:1};case Uo:case Bo:return{byteLength:2,components:4};case xn:case Ni:case qe:return{byteLength:4,components:1};case Mu:case Tu:return{byteLength:4,components:3}}throw new Error(`Unknown texture type ${i}.`)}typeof __THREE_DEVTOOLS__<"u"&&__THREE_DEVTOOLS__.dispatchEvent(new CustomEvent("register",{detail:{revision:"181"}}));typeof window<"u"&&(window.__THREE__?Ze("WARNING: Multiple instances of Three.js being imported."):window.__THREE__="181");function vd(){let i=null,e=!1,t=null,n=null;function r(s,a){t(s,a),n=i.requestAnimationFrame(r)}return{start:function(){e!==!0&&t!==null&&(n=i.requestAnimationFrame(r),e=!0)},stop:function(){i.cancelAnimationFrame(n),e=!1},setAnimationLoop:function(s){t=s},setContext:function(s){i=s}}}function c0(i){let e=new WeakMap;function t(o,c){let u=o.array,f=o.usage,h=u.byteLength,l=i.createBuffer();i.bindBuffer(c,l),i.bufferData(c,u,f),o.onUploadCallback();let p;if(u instanceof Float32Array)p=i.FLOAT;else if(typeof Float16Array<"u"&&u instanceof Float16Array)p=i.HALF_FLOAT;else if(u instanceof Uint16Array)o.isFloat16BufferAttribute?p=i.HALF_FLOAT:p=i.UNSIGNED_SHORT;else if(u instanceof Int16Array)p=i.SHORT;else if(u instanceof Uint32Array)p=i.UNSIGNED_INT;else if(u instanceof Int32Array)p=i.INT;else if(u instanceof Int8Array)p=i.BYTE;else if(u instanceof Uint8Array)p=i.UNSIGNED_BYTE;else if(u instanceof Uint8ClampedArray)p=i.UNSIGNED_BYTE;else throw new Error("THREE.WebGLAttributes: Unsupported buffer data format: "+u);return{buffer:l,type:p,bytesPerElement:u.BYTES_PER_ELEMENT,version:o.version,size:h}}function n(o,c,u){let f=c.array,h=c.updateRanges;if(i.bindBuffer(u,o),h.length===0)i.bufferSubData(u,0,f);else{h.sort((p,g)=>p.start-g.start);let l=0;for(let p=1;p<h.length;p++){let g=h[l],b=h[p];b.start<=g.start+g.count+1?g.count=Math.max(g.count,b.start+b.count-g.start):(++l,h[l]=b)}h.length=l+1;for(let p=0,g=h.length;p<g;p++){let b=h[p];i.bufferSubData(u,b.start*f.BYTES_PER_ELEMENT,f,b.start,b.count)}c.clearUpdateRanges()}c.onUploadCallback()}function r(o){return o.isInterleavedBufferAttribute&&(o=o.data),e.get(o)}function s(o){o.isInterleavedBufferAttribute&&(o=o.data);let c=e.get(o);c&&(i.deleteBuffer(c.buffer),e.delete(o))}function a(o,c){if(o.isInterleavedBufferAttribute&&(o=o.data),o.isGLBufferAttribute){let f=e.get(o);(!f||f.version<o.version)&&e.set(o,{buffer:o.buffer,type:o.type,bytesPerElement:o.elementSize,version:o.version});return}let u=e.get(o);if(u===void 0)e.set(o,t(o,c));else if(u.version<o.version){if(u.size!==o.array.byteLength)throw new Error("THREE.WebGLAttributes: The size of the buffer attribute's array buffer does not match the original size. Resizing buffer attributes is not supported.");n(u.buffer,o,c),u.version=o.version}}return{get:r,remove:s,update:a}}var l0=`#ifdef USE_ALPHAHASH
	if ( diffuseColor.a < getAlphaHashThreshold( vPosition ) ) discard;
#endif`,u0=`#ifdef USE_ALPHAHASH
	const float ALPHA_HASH_SCALE = 0.05;
	float hash2D( vec2 value ) {
		return fract( 1.0e4 * sin( 17.0 * value.x + 0.1 * value.y ) * ( 0.1 + abs( sin( 13.0 * value.y + value.x ) ) ) );
	}
	float hash3D( vec3 value ) {
		return hash2D( vec2( hash2D( value.xy ), value.z ) );
	}
	float getAlphaHashThreshold( vec3 position ) {
		float maxDeriv = max(
			length( dFdx( position.xyz ) ),
			length( dFdy( position.xyz ) )
		);
		float pixScale = 1.0 / ( ALPHA_HASH_SCALE * maxDeriv );
		vec2 pixScales = vec2(
			exp2( floor( log2( pixScale ) ) ),
			exp2( ceil( log2( pixScale ) ) )
		);
		vec2 alpha = vec2(
			hash3D( floor( pixScales.x * position.xyz ) ),
			hash3D( floor( pixScales.y * position.xyz ) )
		);
		float lerpFactor = fract( log2( pixScale ) );
		float x = ( 1.0 - lerpFactor ) * alpha.x + lerpFactor * alpha.y;
		float a = min( lerpFactor, 1.0 - lerpFactor );
		vec3 cases = vec3(
			x * x / ( 2.0 * a * ( 1.0 - a ) ),
			( x - 0.5 * a ) / ( 1.0 - a ),
			1.0 - ( ( 1.0 - x ) * ( 1.0 - x ) / ( 2.0 * a * ( 1.0 - a ) ) )
		);
		float threshold = ( x < ( 1.0 - a ) )
			? ( ( x < a ) ? cases.x : cases.y )
			: cases.z;
		return clamp( threshold , 1.0e-6, 1.0 );
	}
#endif`,h0=`#ifdef USE_ALPHAMAP
	diffuseColor.a *= texture2D( alphaMap, vAlphaMapUv ).g;
#endif`,f0=`#ifdef USE_ALPHAMAP
	uniform sampler2D alphaMap;
#endif`,d0=`#ifdef USE_ALPHATEST
	#ifdef ALPHA_TO_COVERAGE
	diffuseColor.a = smoothstep( alphaTest, alphaTest + fwidth( diffuseColor.a ), diffuseColor.a );
	if ( diffuseColor.a == 0.0 ) discard;
	#else
	if ( diffuseColor.a < alphaTest ) discard;
	#endif
#endif`,p0=`#ifdef USE_ALPHATEST
	uniform float alphaTest;
#endif`,m0=`#ifdef USE_AOMAP
	float ambientOcclusion = ( texture2D( aoMap, vAoMapUv ).r - 1.0 ) * aoMapIntensity + 1.0;
	reflectedLight.indirectDiffuse *= ambientOcclusion;
	#if defined( USE_CLEARCOAT ) 
		clearcoatSpecularIndirect *= ambientOcclusion;
	#endif
	#if defined( USE_SHEEN ) 
		sheenSpecularIndirect *= ambientOcclusion;
	#endif
	#if defined( USE_ENVMAP ) && defined( STANDARD )
		float dotNV = saturate( dot( geometryNormal, geometryViewDir ) );
		reflectedLight.indirectSpecular *= computeSpecularOcclusion( dotNV, ambientOcclusion, material.roughness );
	#endif
#endif`,g0=`#ifdef USE_AOMAP
	uniform sampler2D aoMap;
	uniform float aoMapIntensity;
#endif`,x0=`#ifdef USE_BATCHING
	#if ! defined( GL_ANGLE_multi_draw )
	#define gl_DrawID _gl_DrawID
	uniform int _gl_DrawID;
	#endif
	uniform highp sampler2D batchingTexture;
	uniform highp usampler2D batchingIdTexture;
	mat4 getBatchingMatrix( const in float i ) {
		int size = textureSize( batchingTexture, 0 ).x;
		int j = int( i ) * 4;
		int x = j % size;
		int y = j / size;
		vec4 v1 = texelFetch( batchingTexture, ivec2( x, y ), 0 );
		vec4 v2 = texelFetch( batchingTexture, ivec2( x + 1, y ), 0 );
		vec4 v3 = texelFetch( batchingTexture, ivec2( x + 2, y ), 0 );
		vec4 v4 = texelFetch( batchingTexture, ivec2( x + 3, y ), 0 );
		return mat4( v1, v2, v3, v4 );
	}
	float getIndirectIndex( const in int i ) {
		int size = textureSize( batchingIdTexture, 0 ).x;
		int x = i % size;
		int y = i / size;
		return float( texelFetch( batchingIdTexture, ivec2( x, y ), 0 ).r );
	}
#endif
#ifdef USE_BATCHING_COLOR
	uniform sampler2D batchingColorTexture;
	vec3 getBatchingColor( const in float i ) {
		int size = textureSize( batchingColorTexture, 0 ).x;
		int j = int( i );
		int x = j % size;
		int y = j / size;
		return texelFetch( batchingColorTexture, ivec2( x, y ), 0 ).rgb;
	}
#endif`,v0=`#ifdef USE_BATCHING
	mat4 batchingMatrix = getBatchingMatrix( getIndirectIndex( gl_DrawID ) );
#endif`,_0=`vec3 transformed = vec3( position );
#ifdef USE_ALPHAHASH
	vPosition = vec3( position );
#endif`,y0=`vec3 objectNormal = vec3( normal );
#ifdef USE_TANGENT
	vec3 objectTangent = vec3( tangent.xyz );
#endif`,b0=`float G_BlinnPhong_Implicit( ) {
	return 0.25;
}
float D_BlinnPhong( const in float shininess, const in float dotNH ) {
	return RECIPROCAL_PI * ( shininess * 0.5 + 1.0 ) * pow( dotNH, shininess );
}
vec3 BRDF_BlinnPhong( const in vec3 lightDir, const in vec3 viewDir, const in vec3 normal, const in vec3 specularColor, const in float shininess ) {
	vec3 halfDir = normalize( lightDir + viewDir );
	float dotNH = saturate( dot( normal, halfDir ) );
	float dotVH = saturate( dot( viewDir, halfDir ) );
	vec3 F = F_Schlick( specularColor, 1.0, dotVH );
	float G = G_BlinnPhong_Implicit( );
	float D = D_BlinnPhong( shininess, dotNH );
	return F * ( G * D );
} // validated`,S0=`#ifdef USE_IRIDESCENCE
	const mat3 XYZ_TO_REC709 = mat3(
		 3.2404542, -0.9692660,  0.0556434,
		-1.5371385,  1.8760108, -0.2040259,
		-0.4985314,  0.0415560,  1.0572252
	);
	vec3 Fresnel0ToIor( vec3 fresnel0 ) {
		vec3 sqrtF0 = sqrt( fresnel0 );
		return ( vec3( 1.0 ) + sqrtF0 ) / ( vec3( 1.0 ) - sqrtF0 );
	}
	vec3 IorToFresnel0( vec3 transmittedIor, float incidentIor ) {
		return pow2( ( transmittedIor - vec3( incidentIor ) ) / ( transmittedIor + vec3( incidentIor ) ) );
	}
	float IorToFresnel0( float transmittedIor, float incidentIor ) {
		return pow2( ( transmittedIor - incidentIor ) / ( transmittedIor + incidentIor ));
	}
	vec3 evalSensitivity( float OPD, vec3 shift ) {
		float phase = 2.0 * PI * OPD * 1.0e-9;
		vec3 val = vec3( 5.4856e-13, 4.4201e-13, 5.2481e-13 );
		vec3 pos = vec3( 1.6810e+06, 1.7953e+06, 2.2084e+06 );
		vec3 var = vec3( 4.3278e+09, 9.3046e+09, 6.6121e+09 );
		vec3 xyz = val * sqrt( 2.0 * PI * var ) * cos( pos * phase + shift ) * exp( - pow2( phase ) * var );
		xyz.x += 9.7470e-14 * sqrt( 2.0 * PI * 4.5282e+09 ) * cos( 2.2399e+06 * phase + shift[ 0 ] ) * exp( - 4.5282e+09 * pow2( phase ) );
		xyz /= 1.0685e-7;
		vec3 rgb = XYZ_TO_REC709 * xyz;
		return rgb;
	}
	vec3 evalIridescence( float outsideIOR, float eta2, float cosTheta1, float thinFilmThickness, vec3 baseF0 ) {
		vec3 I;
		float iridescenceIOR = mix( outsideIOR, eta2, smoothstep( 0.0, 0.03, thinFilmThickness ) );
		float sinTheta2Sq = pow2( outsideIOR / iridescenceIOR ) * ( 1.0 - pow2( cosTheta1 ) );
		float cosTheta2Sq = 1.0 - sinTheta2Sq;
		if ( cosTheta2Sq < 0.0 ) {
			return vec3( 1.0 );
		}
		float cosTheta2 = sqrt( cosTheta2Sq );
		float R0 = IorToFresnel0( iridescenceIOR, outsideIOR );
		float R12 = F_Schlick( R0, 1.0, cosTheta1 );
		float T121 = 1.0 - R12;
		float phi12 = 0.0;
		if ( iridescenceIOR < outsideIOR ) phi12 = PI;
		float phi21 = PI - phi12;
		vec3 baseIOR = Fresnel0ToIor( clamp( baseF0, 0.0, 0.9999 ) );		vec3 R1 = IorToFresnel0( baseIOR, iridescenceIOR );
		vec3 R23 = F_Schlick( R1, 1.0, cosTheta2 );
		vec3 phi23 = vec3( 0.0 );
		if ( baseIOR[ 0 ] < iridescenceIOR ) phi23[ 0 ] = PI;
		if ( baseIOR[ 1 ] < iridescenceIOR ) phi23[ 1 ] = PI;
		if ( baseIOR[ 2 ] < iridescenceIOR ) phi23[ 2 ] = PI;
		float OPD = 2.0 * iridescenceIOR * thinFilmThickness * cosTheta2;
		vec3 phi = vec3( phi21 ) + phi23;
		vec3 R123 = clamp( R12 * R23, 1e-5, 0.9999 );
		vec3 r123 = sqrt( R123 );
		vec3 Rs = pow2( T121 ) * R23 / ( vec3( 1.0 ) - R123 );
		vec3 C0 = R12 + Rs;
		I = C0;
		vec3 Cm = Rs - T121;
		for ( int m = 1; m <= 2; ++ m ) {
			Cm *= r123;
			vec3 Sm = 2.0 * evalSensitivity( float( m ) * OPD, float( m ) * phi );
			I += Cm * Sm;
		}
		return max( I, vec3( 0.0 ) );
	}
#endif`,M0=`#ifdef USE_BUMPMAP
	uniform sampler2D bumpMap;
	uniform float bumpScale;
	vec2 dHdxy_fwd() {
		vec2 dSTdx = dFdx( vBumpMapUv );
		vec2 dSTdy = dFdy( vBumpMapUv );
		float Hll = bumpScale * texture2D( bumpMap, vBumpMapUv ).x;
		float dBx = bumpScale * texture2D( bumpMap, vBumpMapUv + dSTdx ).x - Hll;
		float dBy = bumpScale * texture2D( bumpMap, vBumpMapUv + dSTdy ).x - Hll;
		return vec2( dBx, dBy );
	}
	vec3 perturbNormalArb( vec3 surf_pos, vec3 surf_norm, vec2 dHdxy, float faceDirection ) {
		vec3 vSigmaX = normalize( dFdx( surf_pos.xyz ) );
		vec3 vSigmaY = normalize( dFdy( surf_pos.xyz ) );
		vec3 vN = surf_norm;
		vec3 R1 = cross( vSigmaY, vN );
		vec3 R2 = cross( vN, vSigmaX );
		float fDet = dot( vSigmaX, R1 ) * faceDirection;
		vec3 vGrad = sign( fDet ) * ( dHdxy.x * R1 + dHdxy.y * R2 );
		return normalize( abs( fDet ) * surf_norm - vGrad );
	}
#endif`,T0=`#if NUM_CLIPPING_PLANES > 0
	vec4 plane;
	#ifdef ALPHA_TO_COVERAGE
		float distanceToPlane, distanceGradient;
		float clipOpacity = 1.0;
		#pragma unroll_loop_start
		for ( int i = 0; i < UNION_CLIPPING_PLANES; i ++ ) {
			plane = clippingPlanes[ i ];
			distanceToPlane = - dot( vClipPosition, plane.xyz ) + plane.w;
			distanceGradient = fwidth( distanceToPlane ) / 2.0;
			clipOpacity *= smoothstep( - distanceGradient, distanceGradient, distanceToPlane );
			if ( clipOpacity == 0.0 ) discard;
		}
		#pragma unroll_loop_end
		#if UNION_CLIPPING_PLANES < NUM_CLIPPING_PLANES
			float unionClipOpacity = 1.0;
			#pragma unroll_loop_start
			for ( int i = UNION_CLIPPING_PLANES; i < NUM_CLIPPING_PLANES; i ++ ) {
				plane = clippingPlanes[ i ];
				distanceToPlane = - dot( vClipPosition, plane.xyz ) + plane.w;
				distanceGradient = fwidth( distanceToPlane ) / 2.0;
				unionClipOpacity *= 1.0 - smoothstep( - distanceGradient, distanceGradient, distanceToPlane );
			}
			#pragma unroll_loop_end
			clipOpacity *= 1.0 - unionClipOpacity;
		#endif
		diffuseColor.a *= clipOpacity;
		if ( diffuseColor.a == 0.0 ) discard;
	#else
		#pragma unroll_loop_start
		for ( int i = 0; i < UNION_CLIPPING_PLANES; i ++ ) {
			plane = clippingPlanes[ i ];
			if ( dot( vClipPosition, plane.xyz ) > plane.w ) discard;
		}
		#pragma unroll_loop_end
		#if UNION_CLIPPING_PLANES < NUM_CLIPPING_PLANES
			bool clipped = true;
			#pragma unroll_loop_start
			for ( int i = UNION_CLIPPING_PLANES; i < NUM_CLIPPING_PLANES; i ++ ) {
				plane = clippingPlanes[ i ];
				clipped = ( dot( vClipPosition, plane.xyz ) > plane.w ) && clipped;
			}
			#pragma unroll_loop_end
			if ( clipped ) discard;
		#endif
	#endif
#endif`,w0=`#if NUM_CLIPPING_PLANES > 0
	varying vec3 vClipPosition;
	uniform vec4 clippingPlanes[ NUM_CLIPPING_PLANES ];
#endif`,A0=`#if NUM_CLIPPING_PLANES > 0
	varying vec3 vClipPosition;
#endif`,E0=`#if NUM_CLIPPING_PLANES > 0
	vClipPosition = - mvPosition.xyz;
#endif`,C0=`#if defined( USE_COLOR_ALPHA )
	diffuseColor *= vColor;
#elif defined( USE_COLOR )
	diffuseColor.rgb *= vColor;
#endif`,R0=`#if defined( USE_COLOR_ALPHA )
	varying vec4 vColor;
#elif defined( USE_COLOR )
	varying vec3 vColor;
#endif`,I0=`#if defined( USE_COLOR_ALPHA )
	varying vec4 vColor;
#elif defined( USE_COLOR ) || defined( USE_INSTANCING_COLOR ) || defined( USE_BATCHING_COLOR )
	varying vec3 vColor;
#endif`,P0=`#if defined( USE_COLOR_ALPHA )
	vColor = vec4( 1.0 );
#elif defined( USE_COLOR ) || defined( USE_INSTANCING_COLOR ) || defined( USE_BATCHING_COLOR )
	vColor = vec3( 1.0 );
#endif
#ifdef USE_COLOR
	vColor *= color;
#endif
#ifdef USE_INSTANCING_COLOR
	vColor.xyz *= instanceColor.xyz;
#endif
#ifdef USE_BATCHING_COLOR
	vec3 batchingColor = getBatchingColor( getIndirectIndex( gl_DrawID ) );
	vColor.xyz *= batchingColor.xyz;
#endif`,D0=`#define PI 3.141592653589793
#define PI2 6.283185307179586
#define PI_HALF 1.5707963267948966
#define RECIPROCAL_PI 0.3183098861837907
#define RECIPROCAL_PI2 0.15915494309189535
#define EPSILON 1e-6
#ifndef saturate
#define saturate( a ) clamp( a, 0.0, 1.0 )
#endif
#define whiteComplement( a ) ( 1.0 - saturate( a ) )
float pow2( const in float x ) { return x*x; }
vec3 pow2( const in vec3 x ) { return x*x; }
float pow3( const in float x ) { return x*x*x; }
float pow4( const in float x ) { float x2 = x*x; return x2*x2; }
float max3( const in vec3 v ) { return max( max( v.x, v.y ), v.z ); }
float average( const in vec3 v ) { return dot( v, vec3( 0.3333333 ) ); }
highp float rand( const in vec2 uv ) {
	const highp float a = 12.9898, b = 78.233, c = 43758.5453;
	highp float dt = dot( uv.xy, vec2( a,b ) ), sn = mod( dt, PI );
	return fract( sin( sn ) * c );
}
#ifdef HIGH_PRECISION
	float precisionSafeLength( vec3 v ) { return length( v ); }
#else
	float precisionSafeLength( vec3 v ) {
		float maxComponent = max3( abs( v ) );
		return length( v / maxComponent ) * maxComponent;
	}
#endif
struct IncidentLight {
	vec3 color;
	vec3 direction;
	bool visible;
};
struct ReflectedLight {
	vec3 directDiffuse;
	vec3 directSpecular;
	vec3 indirectDiffuse;
	vec3 indirectSpecular;
};
#ifdef USE_ALPHAHASH
	varying vec3 vPosition;
#endif
vec3 transformDirection( in vec3 dir, in mat4 matrix ) {
	return normalize( ( matrix * vec4( dir, 0.0 ) ).xyz );
}
vec3 inverseTransformDirection( in vec3 dir, in mat4 matrix ) {
	return normalize( ( vec4( dir, 0.0 ) * matrix ).xyz );
}
bool isPerspectiveMatrix( mat4 m ) {
	return m[ 2 ][ 3 ] == - 1.0;
}
vec2 equirectUv( in vec3 dir ) {
	float u = atan( dir.z, dir.x ) * RECIPROCAL_PI2 + 0.5;
	float v = asin( clamp( dir.y, - 1.0, 1.0 ) ) * RECIPROCAL_PI + 0.5;
	return vec2( u, v );
}
vec3 BRDF_Lambert( const in vec3 diffuseColor ) {
	return RECIPROCAL_PI * diffuseColor;
}
vec3 F_Schlick( const in vec3 f0, const in float f90, const in float dotVH ) {
	float fresnel = exp2( ( - 5.55473 * dotVH - 6.98316 ) * dotVH );
	return f0 * ( 1.0 - fresnel ) + ( f90 * fresnel );
}
float F_Schlick( const in float f0, const in float f90, const in float dotVH ) {
	float fresnel = exp2( ( - 5.55473 * dotVH - 6.98316 ) * dotVH );
	return f0 * ( 1.0 - fresnel ) + ( f90 * fresnel );
} // validated`,F0=`#ifdef ENVMAP_TYPE_CUBE_UV
	#define cubeUV_minMipLevel 4.0
	#define cubeUV_minTileSize 16.0
	float getFace( vec3 direction ) {
		vec3 absDirection = abs( direction );
		float face = - 1.0;
		if ( absDirection.x > absDirection.z ) {
			if ( absDirection.x > absDirection.y )
				face = direction.x > 0.0 ? 0.0 : 3.0;
			else
				face = direction.y > 0.0 ? 1.0 : 4.0;
		} else {
			if ( absDirection.z > absDirection.y )
				face = direction.z > 0.0 ? 2.0 : 5.0;
			else
				face = direction.y > 0.0 ? 1.0 : 4.0;
		}
		return face;
	}
	vec2 getUV( vec3 direction, float face ) {
		vec2 uv;
		if ( face == 0.0 ) {
			uv = vec2( direction.z, direction.y ) / abs( direction.x );
		} else if ( face == 1.0 ) {
			uv = vec2( - direction.x, - direction.z ) / abs( direction.y );
		} else if ( face == 2.0 ) {
			uv = vec2( - direction.x, direction.y ) / abs( direction.z );
		} else if ( face == 3.0 ) {
			uv = vec2( - direction.z, direction.y ) / abs( direction.x );
		} else if ( face == 4.0 ) {
			uv = vec2( - direction.x, direction.z ) / abs( direction.y );
		} else {
			uv = vec2( direction.x, direction.y ) / abs( direction.z );
		}
		return 0.5 * ( uv + 1.0 );
	}
	vec3 bilinearCubeUV( sampler2D envMap, vec3 direction, float mipInt ) {
		float face = getFace( direction );
		float filterInt = max( cubeUV_minMipLevel - mipInt, 0.0 );
		mipInt = max( mipInt, cubeUV_minMipLevel );
		float faceSize = exp2( mipInt );
		highp vec2 uv = getUV( direction, face ) * ( faceSize - 2.0 ) + 1.0;
		if ( face > 2.0 ) {
			uv.y += faceSize;
			face -= 3.0;
		}
		uv.x += face * faceSize;
		uv.x += filterInt * 3.0 * cubeUV_minTileSize;
		uv.y += 4.0 * ( exp2( CUBEUV_MAX_MIP ) - faceSize );
		uv.x *= CUBEUV_TEXEL_WIDTH;
		uv.y *= CUBEUV_TEXEL_HEIGHT;
		#ifdef texture2DGradEXT
			return texture2DGradEXT( envMap, uv, vec2( 0.0 ), vec2( 0.0 ) ).rgb;
		#else
			return texture2D( envMap, uv ).rgb;
		#endif
	}
	#define cubeUV_r0 1.0
	#define cubeUV_m0 - 2.0
	#define cubeUV_r1 0.8
	#define cubeUV_m1 - 1.0
	#define cubeUV_r4 0.4
	#define cubeUV_m4 2.0
	#define cubeUV_r5 0.305
	#define cubeUV_m5 3.0
	#define cubeUV_r6 0.21
	#define cubeUV_m6 4.0
	float roughnessToMip( float roughness ) {
		float mip = 0.0;
		if ( roughness >= cubeUV_r1 ) {
			mip = ( cubeUV_r0 - roughness ) * ( cubeUV_m1 - cubeUV_m0 ) / ( cubeUV_r0 - cubeUV_r1 ) + cubeUV_m0;
		} else if ( roughness >= cubeUV_r4 ) {
			mip = ( cubeUV_r1 - roughness ) * ( cubeUV_m4 - cubeUV_m1 ) / ( cubeUV_r1 - cubeUV_r4 ) + cubeUV_m1;
		} else if ( roughness >= cubeUV_r5 ) {
			mip = ( cubeUV_r4 - roughness ) * ( cubeUV_m5 - cubeUV_m4 ) / ( cubeUV_r4 - cubeUV_r5 ) + cubeUV_m4;
		} else if ( roughness >= cubeUV_r6 ) {
			mip = ( cubeUV_r5 - roughness ) * ( cubeUV_m6 - cubeUV_m5 ) / ( cubeUV_r5 - cubeUV_r6 ) + cubeUV_m5;
		} else {
			mip = - 2.0 * log2( 1.16 * roughness );		}
		return mip;
	}
	vec4 textureCubeUV( sampler2D envMap, vec3 sampleDir, float roughness ) {
		float mip = clamp( roughnessToMip( roughness ), cubeUV_m0, CUBEUV_MAX_MIP );
		float mipF = fract( mip );
		float mipInt = floor( mip );
		vec3 color0 = bilinearCubeUV( envMap, sampleDir, mipInt );
		if ( mipF == 0.0 ) {
			return vec4( color0, 1.0 );
		} else {
			vec3 color1 = bilinearCubeUV( envMap, sampleDir, mipInt + 1.0 );
			return vec4( mix( color0, color1, mipF ), 1.0 );
		}
	}
#endif`,L0=`vec3 transformedNormal = objectNormal;
#ifdef USE_TANGENT
	vec3 transformedTangent = objectTangent;
#endif
#ifdef USE_BATCHING
	mat3 bm = mat3( batchingMatrix );
	transformedNormal /= vec3( dot( bm[ 0 ], bm[ 0 ] ), dot( bm[ 1 ], bm[ 1 ] ), dot( bm[ 2 ], bm[ 2 ] ) );
	transformedNormal = bm * transformedNormal;
	#ifdef USE_TANGENT
		transformedTangent = bm * transformedTangent;
	#endif
#endif
#ifdef USE_INSTANCING
	mat3 im = mat3( instanceMatrix );
	transformedNormal /= vec3( dot( im[ 0 ], im[ 0 ] ), dot( im[ 1 ], im[ 1 ] ), dot( im[ 2 ], im[ 2 ] ) );
	transformedNormal = im * transformedNormal;
	#ifdef USE_TANGENT
		transformedTangent = im * transformedTangent;
	#endif
#endif
transformedNormal = normalMatrix * transformedNormal;
#ifdef FLIP_SIDED
	transformedNormal = - transformedNormal;
#endif
#ifdef USE_TANGENT
	transformedTangent = ( modelViewMatrix * vec4( transformedTangent, 0.0 ) ).xyz;
	#ifdef FLIP_SIDED
		transformedTangent = - transformedTangent;
	#endif
#endif`,N0=`#ifdef USE_DISPLACEMENTMAP
	uniform sampler2D displacementMap;
	uniform float displacementScale;
	uniform float displacementBias;
#endif`,U0=`#ifdef USE_DISPLACEMENTMAP
	transformed += normalize( objectNormal ) * ( texture2D( displacementMap, vDisplacementMapUv ).x * displacementScale + displacementBias );
#endif`,B0=`#ifdef USE_EMISSIVEMAP
	vec4 emissiveColor = texture2D( emissiveMap, vEmissiveMapUv );
	#ifdef DECODE_VIDEO_TEXTURE_EMISSIVE
		emissiveColor = sRGBTransferEOTF( emissiveColor );
	#endif
	totalEmissiveRadiance *= emissiveColor.rgb;
#endif`,O0=`#ifdef USE_EMISSIVEMAP
	uniform sampler2D emissiveMap;
#endif`,z0="gl_FragColor = linearToOutputTexel( gl_FragColor );",k0=`vec4 LinearTransferOETF( in vec4 value ) {
	return value;
}
vec4 sRGBTransferEOTF( in vec4 value ) {
	return vec4( mix( pow( value.rgb * 0.9478672986 + vec3( 0.0521327014 ), vec3( 2.4 ) ), value.rgb * 0.0773993808, vec3( lessThanEqual( value.rgb, vec3( 0.04045 ) ) ) ), value.a );
}
vec4 sRGBTransferOETF( in vec4 value ) {
	return vec4( mix( pow( value.rgb, vec3( 0.41666 ) ) * 1.055 - vec3( 0.055 ), value.rgb * 12.92, vec3( lessThanEqual( value.rgb, vec3( 0.0031308 ) ) ) ), value.a );
}`,V0=`#ifdef USE_ENVMAP
	#ifdef ENV_WORLDPOS
		vec3 cameraToFrag;
		if ( isOrthographic ) {
			cameraToFrag = normalize( vec3( - viewMatrix[ 0 ][ 2 ], - viewMatrix[ 1 ][ 2 ], - viewMatrix[ 2 ][ 2 ] ) );
		} else {
			cameraToFrag = normalize( vWorldPosition - cameraPosition );
		}
		vec3 worldNormal = inverseTransformDirection( normal, viewMatrix );
		#ifdef ENVMAP_MODE_REFLECTION
			vec3 reflectVec = reflect( cameraToFrag, worldNormal );
		#else
			vec3 reflectVec = refract( cameraToFrag, worldNormal, refractionRatio );
		#endif
	#else
		vec3 reflectVec = vReflect;
	#endif
	#ifdef ENVMAP_TYPE_CUBE
		vec4 envColor = textureCube( envMap, envMapRotation * vec3( flipEnvMap * reflectVec.x, reflectVec.yz ) );
	#else
		vec4 envColor = vec4( 0.0 );
	#endif
	#ifdef ENVMAP_BLENDING_MULTIPLY
		outgoingLight = mix( outgoingLight, outgoingLight * envColor.xyz, specularStrength * reflectivity );
	#elif defined( ENVMAP_BLENDING_MIX )
		outgoingLight = mix( outgoingLight, envColor.xyz, specularStrength * reflectivity );
	#elif defined( ENVMAP_BLENDING_ADD )
		outgoingLight += envColor.xyz * specularStrength * reflectivity;
	#endif
#endif`,H0=`#ifdef USE_ENVMAP
	uniform float envMapIntensity;
	uniform float flipEnvMap;
	uniform mat3 envMapRotation;
	#ifdef ENVMAP_TYPE_CUBE
		uniform samplerCube envMap;
	#else
		uniform sampler2D envMap;
	#endif
#endif`,G0=`#ifdef USE_ENVMAP
	uniform float reflectivity;
	#if defined( USE_BUMPMAP ) || defined( USE_NORMALMAP ) || defined( PHONG ) || defined( LAMBERT )
		#define ENV_WORLDPOS
	#endif
	#ifdef ENV_WORLDPOS
		varying vec3 vWorldPosition;
		uniform float refractionRatio;
	#else
		varying vec3 vReflect;
	#endif
#endif`,W0=`#ifdef USE_ENVMAP
	#if defined( USE_BUMPMAP ) || defined( USE_NORMALMAP ) || defined( PHONG ) || defined( LAMBERT )
		#define ENV_WORLDPOS
	#endif
	#ifdef ENV_WORLDPOS
		
		varying vec3 vWorldPosition;
	#else
		varying vec3 vReflect;
		uniform float refractionRatio;
	#endif
#endif`,X0=`#ifdef USE_ENVMAP
	#ifdef ENV_WORLDPOS
		vWorldPosition = worldPosition.xyz;
	#else
		vec3 cameraToVertex;
		if ( isOrthographic ) {
			cameraToVertex = normalize( vec3( - viewMatrix[ 0 ][ 2 ], - viewMatrix[ 1 ][ 2 ], - viewMatrix[ 2 ][ 2 ] ) );
		} else {
			cameraToVertex = normalize( worldPosition.xyz - cameraPosition );
		}
		vec3 worldNormal = inverseTransformDirection( transformedNormal, viewMatrix );
		#ifdef ENVMAP_MODE_REFLECTION
			vReflect = reflect( cameraToVertex, worldNormal );
		#else
			vReflect = refract( cameraToVertex, worldNormal, refractionRatio );
		#endif
	#endif
#endif`,q0=`#ifdef USE_FOG
	vFogDepth = - mvPosition.z;
#endif`,Y0=`#ifdef USE_FOG
	varying float vFogDepth;
#endif`,Z0=`#ifdef USE_FOG
	#ifdef FOG_EXP2
		float fogFactor = 1.0 - exp( - fogDensity * fogDensity * vFogDepth * vFogDepth );
	#else
		float fogFactor = smoothstep( fogNear, fogFar, vFogDepth );
	#endif
	gl_FragColor.rgb = mix( gl_FragColor.rgb, fogColor, fogFactor );
#endif`,$0=`#ifdef USE_FOG
	uniform vec3 fogColor;
	varying float vFogDepth;
	#ifdef FOG_EXP2
		uniform float fogDensity;
	#else
		uniform float fogNear;
		uniform float fogFar;
	#endif
#endif`,J0=`#ifdef USE_GRADIENTMAP
	uniform sampler2D gradientMap;
#endif
vec3 getGradientIrradiance( vec3 normal, vec3 lightDirection ) {
	float dotNL = dot( normal, lightDirection );
	vec2 coord = vec2( dotNL * 0.5 + 0.5, 0.0 );
	#ifdef USE_GRADIENTMAP
		return vec3( texture2D( gradientMap, coord ).r );
	#else
		vec2 fw = fwidth( coord ) * 0.5;
		return mix( vec3( 0.7 ), vec3( 1.0 ), smoothstep( 0.7 - fw.x, 0.7 + fw.x, coord.x ) );
	#endif
}`,K0=`#ifdef USE_LIGHTMAP
	uniform sampler2D lightMap;
	uniform float lightMapIntensity;
#endif`,Q0=`LambertMaterial material;
material.diffuseColor = diffuseColor.rgb;
material.specularStrength = specularStrength;`,j0=`varying vec3 vViewPosition;
struct LambertMaterial {
	vec3 diffuseColor;
	float specularStrength;
};
void RE_Direct_Lambert( const in IncidentLight directLight, const in vec3 geometryPosition, const in vec3 geometryNormal, const in vec3 geometryViewDir, const in vec3 geometryClearcoatNormal, const in LambertMaterial material, inout ReflectedLight reflectedLight ) {
	float dotNL = saturate( dot( geometryNormal, directLight.direction ) );
	vec3 irradiance = dotNL * directLight.color;
	reflectedLight.directDiffuse += irradiance * BRDF_Lambert( material.diffuseColor );
}
void RE_IndirectDiffuse_Lambert( const in vec3 irradiance, const in vec3 geometryPosition, const in vec3 geometryNormal, const in vec3 geometryViewDir, const in vec3 geometryClearcoatNormal, const in LambertMaterial material, inout ReflectedLight reflectedLight ) {
	reflectedLight.indirectDiffuse += irradiance * BRDF_Lambert( material.diffuseColor );
}
#define RE_Direct				RE_Direct_Lambert
#define RE_IndirectDiffuse		RE_IndirectDiffuse_Lambert`,eg=`uniform bool receiveShadow;
uniform vec3 ambientLightColor;
#if defined( USE_LIGHT_PROBES )
	uniform vec3 lightProbe[ 9 ];
#endif
vec3 shGetIrradianceAt( in vec3 normal, in vec3 shCoefficients[ 9 ] ) {
	float x = normal.x, y = normal.y, z = normal.z;
	vec3 result = shCoefficients[ 0 ] * 0.886227;
	result += shCoefficients[ 1 ] * 2.0 * 0.511664 * y;
	result += shCoefficients[ 2 ] * 2.0 * 0.511664 * z;
	result += shCoefficients[ 3 ] * 2.0 * 0.511664 * x;
	result += shCoefficients[ 4 ] * 2.0 * 0.429043 * x * y;
	result += shCoefficients[ 5 ] * 2.0 * 0.429043 * y * z;
	result += shCoefficients[ 6 ] * ( 0.743125 * z * z - 0.247708 );
	result += shCoefficients[ 7 ] * 2.0 * 0.429043 * x * z;
	result += shCoefficients[ 8 ] * 0.429043 * ( x * x - y * y );
	return result;
}
vec3 getLightProbeIrradiance( const in vec3 lightProbe[ 9 ], const in vec3 normal ) {
	vec3 worldNormal = inverseTransformDirection( normal, viewMatrix );
	vec3 irradiance = shGetIrradianceAt( worldNormal, lightProbe );
	return irradiance;
}
vec3 getAmbientLightIrradiance( const in vec3 ambientLightColor ) {
	vec3 irradiance = ambientLightColor;
	return irradiance;
}
float getDistanceAttenuation( const in float lightDistance, const in float cutoffDistance, const in float decayExponent ) {
	float distanceFalloff = 1.0 / max( pow( lightDistance, decayExponent ), 0.01 );
	if ( cutoffDistance > 0.0 ) {
		distanceFalloff *= pow2( saturate( 1.0 - pow4( lightDistance / cutoffDistance ) ) );
	}
	return distanceFalloff;
}
float getSpotAttenuation( const in float coneCosine, const in float penumbraCosine, const in float angleCosine ) {
	return smoothstep( coneCosine, penumbraCosine, angleCosine );
}
#if NUM_DIR_LIGHTS > 0
	struct DirectionalLight {
		vec3 direction;
		vec3 color;
	};
	uniform DirectionalLight directionalLights[ NUM_DIR_LIGHTS ];
	void getDirectionalLightInfo( const in DirectionalLight directionalLight, out IncidentLight light ) {
		light.color = directionalLight.color;
		light.direction = directionalLight.direction;
		light.visible = true;
	}
#endif
#if NUM_POINT_LIGHTS > 0
	struct PointLight {
		vec3 position;
		vec3 color;
		float distance;
		float decay;
	};
	uniform PointLight pointLights[ NUM_POINT_LIGHTS ];
	void getPointLightInfo( const in PointLight pointLight, const in vec3 geometryPosition, out IncidentLight light ) {
		vec3 lVector = pointLight.position - geometryPosition;
		light.direction = normalize( lVector );
		float lightDistance = length( lVector );
		light.color = pointLight.color;
		light.color *= getDistanceAttenuation( lightDistance, pointLight.distance, pointLight.decay );
		light.visible = ( light.color != vec3( 0.0 ) );
	}
#endif
#if NUM_SPOT_LIGHTS > 0
	struct SpotLight {
		vec3 position;
		vec3 direction;
		vec3 color;
		float distance;
		float decay;
		float coneCos;
		float penumbraCos;
	};
	uniform SpotLight spotLights[ NUM_SPOT_LIGHTS ];
	void getSpotLightInfo( const in SpotLight spotLight, const in vec3 geometryPosition, out IncidentLight light ) {
		vec3 lVector = spotLight.position - geometryPosition;
		light.direction = normalize( lVector );
		float angleCos = dot( light.direction, spotLight.direction );
		float spotAttenuation = getSpotAttenuation( spotLight.coneCos, spotLight.penumbraCos, angleCos );
		if ( spotAttenuation > 0.0 ) {
			float lightDistance = length( lVector );
			light.color = spotLight.color * spotAttenuation;
			light.color *= getDistanceAttenuation( lightDistance, spotLight.distance, spotLight.decay );
			light.visible = ( light.color != vec3( 0.0 ) );
		} else {
			light.color = vec3( 0.0 );
			light.visible = false;
		}
	}
#endif
#if NUM_RECT_AREA_LIGHTS > 0
	struct RectAreaLight {
		vec3 color;
		vec3 position;
		vec3 halfWidth;
		vec3 halfHeight;
	};
	uniform sampler2D ltc_1;	uniform sampler2D ltc_2;
	uniform RectAreaLight rectAreaLights[ NUM_RECT_AREA_LIGHTS ];
#endif
#if NUM_HEMI_LIGHTS > 0
	struct HemisphereLight {
		vec3 direction;
		vec3 skyColor;
		vec3 groundColor;
	};
	uniform HemisphereLight hemisphereLights[ NUM_HEMI_LIGHTS ];
	vec3 getHemisphereLightIrradiance( const in HemisphereLight hemiLight, const in vec3 normal ) {
		float dotNL = dot( normal, hemiLight.direction );
		float hemiDiffuseWeight = 0.5 * dotNL + 0.5;
		vec3 irradiance = mix( hemiLight.groundColor, hemiLight.skyColor, hemiDiffuseWeight );
		return irradiance;
	}
#endif`,tg=`#ifdef USE_ENVMAP
	vec3 getIBLIrradiance( const in vec3 normal ) {
		#ifdef ENVMAP_TYPE_CUBE_UV
			vec3 worldNormal = inverseTransformDirection( normal, viewMatrix );
			vec4 envMapColor = textureCubeUV( envMap, envMapRotation * worldNormal, 1.0 );
			return PI * envMapColor.rgb * envMapIntensity;
		#else
			return vec3( 0.0 );
		#endif
	}
	vec3 getIBLRadiance( const in vec3 viewDir, const in vec3 normal, const in float roughness ) {
		#ifdef ENVMAP_TYPE_CUBE_UV
			vec3 reflectVec = reflect( - viewDir, normal );
			reflectVec = normalize( mix( reflectVec, normal, pow4( roughness ) ) );
			reflectVec = inverseTransformDirection( reflectVec, viewMatrix );
			vec4 envMapColor = textureCubeUV( envMap, envMapRotation * reflectVec, roughness );
			return envMapColor.rgb * envMapIntensity;
		#else
			return vec3( 0.0 );
		#endif
	}
	#ifdef USE_ANISOTROPY
		vec3 getIBLAnisotropyRadiance( const in vec3 viewDir, const in vec3 normal, const in float roughness, const in vec3 bitangent, const in float anisotropy ) {
			#ifdef ENVMAP_TYPE_CUBE_UV
				vec3 bentNormal = cross( bitangent, viewDir );
				bentNormal = normalize( cross( bentNormal, bitangent ) );
				bentNormal = normalize( mix( bentNormal, normal, pow2( pow2( 1.0 - anisotropy * ( 1.0 - roughness ) ) ) ) );
				return getIBLRadiance( viewDir, bentNormal, roughness );
			#else
				return vec3( 0.0 );
			#endif
		}
	#endif
#endif`,ng=`ToonMaterial material;
material.diffuseColor = diffuseColor.rgb;`,ig=`varying vec3 vViewPosition;
struct ToonMaterial {
	vec3 diffuseColor;
};
void RE_Direct_Toon( const in IncidentLight directLight, const in vec3 geometryPosition, const in vec3 geometryNormal, const in vec3 geometryViewDir, const in vec3 geometryClearcoatNormal, const in ToonMaterial material, inout ReflectedLight reflectedLight ) {
	vec3 irradiance = getGradientIrradiance( geometryNormal, directLight.direction ) * directLight.color;
	reflectedLight.directDiffuse += irradiance * BRDF_Lambert( material.diffuseColor );
}
void RE_IndirectDiffuse_Toon( const in vec3 irradiance, const in vec3 geometryPosition, const in vec3 geometryNormal, const in vec3 geometryViewDir, const in vec3 geometryClearcoatNormal, const in ToonMaterial material, inout ReflectedLight reflectedLight ) {
	reflectedLight.indirectDiffuse += irradiance * BRDF_Lambert( material.diffuseColor );
}
#define RE_Direct				RE_Direct_Toon
#define RE_IndirectDiffuse		RE_IndirectDiffuse_Toon`,rg=`BlinnPhongMaterial material;
material.diffuseColor = diffuseColor.rgb;
material.specularColor = specular;
material.specularShininess = shininess;
material.specularStrength = specularStrength;`,sg=`varying vec3 vViewPosition;
struct BlinnPhongMaterial {
	vec3 diffuseColor;
	vec3 specularColor;
	float specularShininess;
	float specularStrength;
};
void RE_Direct_BlinnPhong( const in IncidentLight directLight, const in vec3 geometryPosition, const in vec3 geometryNormal, const in vec3 geometryViewDir, const in vec3 geometryClearcoatNormal, const in BlinnPhongMaterial material, inout ReflectedLight reflectedLight ) {
	float dotNL = saturate( dot( geometryNormal, directLight.direction ) );
	vec3 irradiance = dotNL * directLight.color;
	reflectedLight.directDiffuse += irradiance * BRDF_Lambert( material.diffuseColor );
	reflectedLight.directSpecular += irradiance * BRDF_BlinnPhong( directLight.direction, geometryViewDir, geometryNormal, material.specularColor, material.specularShininess ) * material.specularStrength;
}
void RE_IndirectDiffuse_BlinnPhong( const in vec3 irradiance, const in vec3 geometryPosition, const in vec3 geometryNormal, const in vec3 geometryViewDir, const in vec3 geometryClearcoatNormal, const in BlinnPhongMaterial material, inout ReflectedLight reflectedLight ) {
	reflectedLight.indirectDiffuse += irradiance * BRDF_Lambert( material.diffuseColor );
}
#define RE_Direct				RE_Direct_BlinnPhong
#define RE_IndirectDiffuse		RE_IndirectDiffuse_BlinnPhong`,ag=`PhysicalMaterial material;
material.diffuseColor = diffuseColor.rgb * ( 1.0 - metalnessFactor );
vec3 dxy = max( abs( dFdx( nonPerturbedNormal ) ), abs( dFdy( nonPerturbedNormal ) ) );
float geometryRoughness = max( max( dxy.x, dxy.y ), dxy.z );
material.roughness = max( roughnessFactor, 0.0525 );material.roughness += geometryRoughness;
material.roughness = min( material.roughness, 1.0 );
#ifdef IOR
	material.ior = ior;
	#ifdef USE_SPECULAR
		float specularIntensityFactor = specularIntensity;
		vec3 specularColorFactor = specularColor;
		#ifdef USE_SPECULAR_COLORMAP
			specularColorFactor *= texture2D( specularColorMap, vSpecularColorMapUv ).rgb;
		#endif
		#ifdef USE_SPECULAR_INTENSITYMAP
			specularIntensityFactor *= texture2D( specularIntensityMap, vSpecularIntensityMapUv ).a;
		#endif
		material.specularF90 = mix( specularIntensityFactor, 1.0, metalnessFactor );
	#else
		float specularIntensityFactor = 1.0;
		vec3 specularColorFactor = vec3( 1.0 );
		material.specularF90 = 1.0;
	#endif
	material.specularColor = mix( min( pow2( ( material.ior - 1.0 ) / ( material.ior + 1.0 ) ) * specularColorFactor, vec3( 1.0 ) ) * specularIntensityFactor, diffuseColor.rgb, metalnessFactor );
#else
	material.specularColor = mix( vec3( 0.04 ), diffuseColor.rgb, metalnessFactor );
	material.specularF90 = 1.0;
#endif
#ifdef USE_CLEARCOAT
	material.clearcoat = clearcoat;
	material.clearcoatRoughness = clearcoatRoughness;
	material.clearcoatF0 = vec3( 0.04 );
	material.clearcoatF90 = 1.0;
	#ifdef USE_CLEARCOATMAP
		material.clearcoat *= texture2D( clearcoatMap, vClearcoatMapUv ).x;
	#endif
	#ifdef USE_CLEARCOAT_ROUGHNESSMAP
		material.clearcoatRoughness *= texture2D( clearcoatRoughnessMap, vClearcoatRoughnessMapUv ).y;
	#endif
	material.clearcoat = saturate( material.clearcoat );	material.clearcoatRoughness = max( material.clearcoatRoughness, 0.0525 );
	material.clearcoatRoughness += geometryRoughness;
	material.clearcoatRoughness = min( material.clearcoatRoughness, 1.0 );
#endif
#ifdef USE_DISPERSION
	material.dispersion = dispersion;
#endif
#ifdef USE_IRIDESCENCE
	material.iridescence = iridescence;
	material.iridescenceIOR = iridescenceIOR;
	#ifdef USE_IRIDESCENCEMAP
		material.iridescence *= texture2D( iridescenceMap, vIridescenceMapUv ).r;
	#endif
	#ifdef USE_IRIDESCENCE_THICKNESSMAP
		material.iridescenceThickness = (iridescenceThicknessMaximum - iridescenceThicknessMinimum) * texture2D( iridescenceThicknessMap, vIridescenceThicknessMapUv ).g + iridescenceThicknessMinimum;
	#else
		material.iridescenceThickness = iridescenceThicknessMaximum;
	#endif
#endif
#ifdef USE_SHEEN
	material.sheenColor = sheenColor;
	#ifdef USE_SHEEN_COLORMAP
		material.sheenColor *= texture2D( sheenColorMap, vSheenColorMapUv ).rgb;
	#endif
	material.sheenRoughness = clamp( sheenRoughness, 0.07, 1.0 );
	#ifdef USE_SHEEN_ROUGHNESSMAP
		material.sheenRoughness *= texture2D( sheenRoughnessMap, vSheenRoughnessMapUv ).a;
	#endif
#endif
#ifdef USE_ANISOTROPY
	#ifdef USE_ANISOTROPYMAP
		mat2 anisotropyMat = mat2( anisotropyVector.x, anisotropyVector.y, - anisotropyVector.y, anisotropyVector.x );
		vec3 anisotropyPolar = texture2D( anisotropyMap, vAnisotropyMapUv ).rgb;
		vec2 anisotropyV = anisotropyMat * normalize( 2.0 * anisotropyPolar.rg - vec2( 1.0 ) ) * anisotropyPolar.b;
	#else
		vec2 anisotropyV = anisotropyVector;
	#endif
	material.anisotropy = length( anisotropyV );
	if( material.anisotropy == 0.0 ) {
		anisotropyV = vec2( 1.0, 0.0 );
	} else {
		anisotropyV /= material.anisotropy;
		material.anisotropy = saturate( material.anisotropy );
	}
	material.alphaT = mix( pow2( material.roughness ), 1.0, pow2( material.anisotropy ) );
	material.anisotropyT = tbn[ 0 ] * anisotropyV.x + tbn[ 1 ] * anisotropyV.y;
	material.anisotropyB = tbn[ 1 ] * anisotropyV.x - tbn[ 0 ] * anisotropyV.y;
#endif`,og=`uniform sampler2D dfgLUT;
struct PhysicalMaterial {
	vec3 diffuseColor;
	float roughness;
	vec3 specularColor;
	float specularF90;
	float dispersion;
	#ifdef USE_CLEARCOAT
		float clearcoat;
		float clearcoatRoughness;
		vec3 clearcoatF0;
		float clearcoatF90;
	#endif
	#ifdef USE_IRIDESCENCE
		float iridescence;
		float iridescenceIOR;
		float iridescenceThickness;
		vec3 iridescenceFresnel;
		vec3 iridescenceF0;
	#endif
	#ifdef USE_SHEEN
		vec3 sheenColor;
		float sheenRoughness;
	#endif
	#ifdef IOR
		float ior;
	#endif
	#ifdef USE_TRANSMISSION
		float transmission;
		float transmissionAlpha;
		float thickness;
		float attenuationDistance;
		vec3 attenuationColor;
	#endif
	#ifdef USE_ANISOTROPY
		float anisotropy;
		float alphaT;
		vec3 anisotropyT;
		vec3 anisotropyB;
	#endif
};
vec3 clearcoatSpecularDirect = vec3( 0.0 );
vec3 clearcoatSpecularIndirect = vec3( 0.0 );
vec3 sheenSpecularDirect = vec3( 0.0 );
vec3 sheenSpecularIndirect = vec3(0.0 );
vec3 Schlick_to_F0( const in vec3 f, const in float f90, const in float dotVH ) {
    float x = clamp( 1.0 - dotVH, 0.0, 1.0 );
    float x2 = x * x;
    float x5 = clamp( x * x2 * x2, 0.0, 0.9999 );
    return ( f - vec3( f90 ) * x5 ) / ( 1.0 - x5 );
}
float V_GGX_SmithCorrelated( const in float alpha, const in float dotNL, const in float dotNV ) {
	float a2 = pow2( alpha );
	float gv = dotNL * sqrt( a2 + ( 1.0 - a2 ) * pow2( dotNV ) );
	float gl = dotNV * sqrt( a2 + ( 1.0 - a2 ) * pow2( dotNL ) );
	return 0.5 / max( gv + gl, EPSILON );
}
float D_GGX( const in float alpha, const in float dotNH ) {
	float a2 = pow2( alpha );
	float denom = pow2( dotNH ) * ( a2 - 1.0 ) + 1.0;
	return RECIPROCAL_PI * a2 / pow2( denom );
}
#ifdef USE_ANISOTROPY
	float V_GGX_SmithCorrelated_Anisotropic( const in float alphaT, const in float alphaB, const in float dotTV, const in float dotBV, const in float dotTL, const in float dotBL, const in float dotNV, const in float dotNL ) {
		float gv = dotNL * length( vec3( alphaT * dotTV, alphaB * dotBV, dotNV ) );
		float gl = dotNV * length( vec3( alphaT * dotTL, alphaB * dotBL, dotNL ) );
		float v = 0.5 / ( gv + gl );
		return saturate(v);
	}
	float D_GGX_Anisotropic( const in float alphaT, const in float alphaB, const in float dotNH, const in float dotTH, const in float dotBH ) {
		float a2 = alphaT * alphaB;
		highp vec3 v = vec3( alphaB * dotTH, alphaT * dotBH, a2 * dotNH );
		highp float v2 = dot( v, v );
		float w2 = a2 / v2;
		return RECIPROCAL_PI * a2 * pow2 ( w2 );
	}
#endif
#ifdef USE_CLEARCOAT
	vec3 BRDF_GGX_Clearcoat( const in vec3 lightDir, const in vec3 viewDir, const in vec3 normal, const in PhysicalMaterial material) {
		vec3 f0 = material.clearcoatF0;
		float f90 = material.clearcoatF90;
		float roughness = material.clearcoatRoughness;
		float alpha = pow2( roughness );
		vec3 halfDir = normalize( lightDir + viewDir );
		float dotNL = saturate( dot( normal, lightDir ) );
		float dotNV = saturate( dot( normal, viewDir ) );
		float dotNH = saturate( dot( normal, halfDir ) );
		float dotVH = saturate( dot( viewDir, halfDir ) );
		vec3 F = F_Schlick( f0, f90, dotVH );
		float V = V_GGX_SmithCorrelated( alpha, dotNL, dotNV );
		float D = D_GGX( alpha, dotNH );
		return F * ( V * D );
	}
#endif
vec3 BRDF_GGX( const in vec3 lightDir, const in vec3 viewDir, const in vec3 normal, const in PhysicalMaterial material ) {
	vec3 f0 = material.specularColor;
	float f90 = material.specularF90;
	float roughness = material.roughness;
	float alpha = pow2( roughness );
	vec3 halfDir = normalize( lightDir + viewDir );
	float dotNL = saturate( dot( normal, lightDir ) );
	float dotNV = saturate( dot( normal, viewDir ) );
	float dotNH = saturate( dot( normal, halfDir ) );
	float dotVH = saturate( dot( viewDir, halfDir ) );
	vec3 F = F_Schlick( f0, f90, dotVH );
	#ifdef USE_IRIDESCENCE
		F = mix( F, material.iridescenceFresnel, material.iridescence );
	#endif
	#ifdef USE_ANISOTROPY
		float dotTL = dot( material.anisotropyT, lightDir );
		float dotTV = dot( material.anisotropyT, viewDir );
		float dotTH = dot( material.anisotropyT, halfDir );
		float dotBL = dot( material.anisotropyB, lightDir );
		float dotBV = dot( material.anisotropyB, viewDir );
		float dotBH = dot( material.anisotropyB, halfDir );
		float V = V_GGX_SmithCorrelated_Anisotropic( material.alphaT, alpha, dotTV, dotBV, dotTL, dotBL, dotNV, dotNL );
		float D = D_GGX_Anisotropic( material.alphaT, alpha, dotNH, dotTH, dotBH );
	#else
		float V = V_GGX_SmithCorrelated( alpha, dotNL, dotNV );
		float D = D_GGX( alpha, dotNH );
	#endif
	return F * ( V * D );
}
vec2 LTC_Uv( const in vec3 N, const in vec3 V, const in float roughness ) {
	const float LUT_SIZE = 64.0;
	const float LUT_SCALE = ( LUT_SIZE - 1.0 ) / LUT_SIZE;
	const float LUT_BIAS = 0.5 / LUT_SIZE;
	float dotNV = saturate( dot( N, V ) );
	vec2 uv = vec2( roughness, sqrt( 1.0 - dotNV ) );
	uv = uv * LUT_SCALE + LUT_BIAS;
	return uv;
}
float LTC_ClippedSphereFormFactor( const in vec3 f ) {
	float l = length( f );
	return max( ( l * l + f.z ) / ( l + 1.0 ), 0.0 );
}
vec3 LTC_EdgeVectorFormFactor( const in vec3 v1, const in vec3 v2 ) {
	float x = dot( v1, v2 );
	float y = abs( x );
	float a = 0.8543985 + ( 0.4965155 + 0.0145206 * y ) * y;
	float b = 3.4175940 + ( 4.1616724 + y ) * y;
	float v = a / b;
	float theta_sintheta = ( x > 0.0 ) ? v : 0.5 * inversesqrt( max( 1.0 - x * x, 1e-7 ) ) - v;
	return cross( v1, v2 ) * theta_sintheta;
}
vec3 LTC_Evaluate( const in vec3 N, const in vec3 V, const in vec3 P, const in mat3 mInv, const in vec3 rectCoords[ 4 ] ) {
	vec3 v1 = rectCoords[ 1 ] - rectCoords[ 0 ];
	vec3 v2 = rectCoords[ 3 ] - rectCoords[ 0 ];
	vec3 lightNormal = cross( v1, v2 );
	if( dot( lightNormal, P - rectCoords[ 0 ] ) < 0.0 ) return vec3( 0.0 );
	vec3 T1, T2;
	T1 = normalize( V - N * dot( V, N ) );
	T2 = - cross( N, T1 );
	mat3 mat = mInv * transpose( mat3( T1, T2, N ) );
	vec3 coords[ 4 ];
	coords[ 0 ] = mat * ( rectCoords[ 0 ] - P );
	coords[ 1 ] = mat * ( rectCoords[ 1 ] - P );
	coords[ 2 ] = mat * ( rectCoords[ 2 ] - P );
	coords[ 3 ] = mat * ( rectCoords[ 3 ] - P );
	coords[ 0 ] = normalize( coords[ 0 ] );
	coords[ 1 ] = normalize( coords[ 1 ] );
	coords[ 2 ] = normalize( coords[ 2 ] );
	coords[ 3 ] = normalize( coords[ 3 ] );
	vec3 vectorFormFactor = vec3( 0.0 );
	vectorFormFactor += LTC_EdgeVectorFormFactor( coords[ 0 ], coords[ 1 ] );
	vectorFormFactor += LTC_EdgeVectorFormFactor( coords[ 1 ], coords[ 2 ] );
	vectorFormFactor += LTC_EdgeVectorFormFactor( coords[ 2 ], coords[ 3 ] );
	vectorFormFactor += LTC_EdgeVectorFormFactor( coords[ 3 ], coords[ 0 ] );
	float result = LTC_ClippedSphereFormFactor( vectorFormFactor );
	return vec3( result );
}
#if defined( USE_SHEEN )
float D_Charlie( float roughness, float dotNH ) {
	float alpha = pow2( roughness );
	float invAlpha = 1.0 / alpha;
	float cos2h = dotNH * dotNH;
	float sin2h = max( 1.0 - cos2h, 0.0078125 );
	return ( 2.0 + invAlpha ) * pow( sin2h, invAlpha * 0.5 ) / ( 2.0 * PI );
}
float V_Neubelt( float dotNV, float dotNL ) {
	return saturate( 1.0 / ( 4.0 * ( dotNL + dotNV - dotNL * dotNV ) ) );
}
vec3 BRDF_Sheen( const in vec3 lightDir, const in vec3 viewDir, const in vec3 normal, vec3 sheenColor, const in float sheenRoughness ) {
	vec3 halfDir = normalize( lightDir + viewDir );
	float dotNL = saturate( dot( normal, lightDir ) );
	float dotNV = saturate( dot( normal, viewDir ) );
	float dotNH = saturate( dot( normal, halfDir ) );
	float D = D_Charlie( sheenRoughness, dotNH );
	float V = V_Neubelt( dotNV, dotNL );
	return sheenColor * ( D * V );
}
#endif
float IBLSheenBRDF( const in vec3 normal, const in vec3 viewDir, const in float roughness ) {
	float dotNV = saturate( dot( normal, viewDir ) );
	float r2 = roughness * roughness;
	float a = roughness < 0.25 ? -339.2 * r2 + 161.4 * roughness - 25.9 : -8.48 * r2 + 14.3 * roughness - 9.95;
	float b = roughness < 0.25 ? 44.0 * r2 - 23.7 * roughness + 3.26 : 1.97 * r2 - 3.27 * roughness + 0.72;
	float DG = exp( a * dotNV + b ) + ( roughness < 0.25 ? 0.0 : 0.1 * ( roughness - 0.25 ) );
	return saturate( DG * RECIPROCAL_PI );
}
vec2 DFGApprox( const in vec3 normal, const in vec3 viewDir, const in float roughness ) {
	float dotNV = saturate( dot( normal, viewDir ) );
	vec2 uv = vec2( roughness, dotNV );
	return texture2D( dfgLUT, uv ).rg;
}
vec3 EnvironmentBRDF( const in vec3 normal, const in vec3 viewDir, const in vec3 specularColor, const in float specularF90, const in float roughness ) {
	vec2 fab = DFGApprox( normal, viewDir, roughness );
	return specularColor * fab.x + specularF90 * fab.y;
}
#ifdef USE_IRIDESCENCE
void computeMultiscatteringIridescence( const in vec3 normal, const in vec3 viewDir, const in vec3 specularColor, const in float specularF90, const in float iridescence, const in vec3 iridescenceF0, const in float roughness, inout vec3 singleScatter, inout vec3 multiScatter ) {
#else
void computeMultiscattering( const in vec3 normal, const in vec3 viewDir, const in vec3 specularColor, const in float specularF90, const in float roughness, inout vec3 singleScatter, inout vec3 multiScatter ) {
#endif
	vec2 fab = DFGApprox( normal, viewDir, roughness );
	#ifdef USE_IRIDESCENCE
		vec3 Fr = mix( specularColor, iridescenceF0, iridescence );
	#else
		vec3 Fr = specularColor;
	#endif
	vec3 FssEss = Fr * fab.x + specularF90 * fab.y;
	float Ess = fab.x + fab.y;
	float Ems = 1.0 - Ess;
	vec3 Favg = Fr + ( 1.0 - Fr ) * 0.047619;	vec3 Fms = FssEss * Favg / ( 1.0 - Ems * Favg );
	singleScatter += FssEss;
	multiScatter += Fms * Ems;
}
vec3 BRDF_GGX_Multiscatter( const in vec3 lightDir, const in vec3 viewDir, const in vec3 normal, const in PhysicalMaterial material ) {
	vec3 singleScatter = BRDF_GGX( lightDir, viewDir, normal, material );
	float dotNL = saturate( dot( normal, lightDir ) );
	float dotNV = saturate( dot( normal, viewDir ) );
	vec2 dfgV = DFGApprox( vec3(0.0, 0.0, 1.0), vec3(sqrt(1.0 - dotNV * dotNV), 0.0, dotNV), material.roughness );
	vec2 dfgL = DFGApprox( vec3(0.0, 0.0, 1.0), vec3(sqrt(1.0 - dotNL * dotNL), 0.0, dotNL), material.roughness );
	vec3 FssEss_V = material.specularColor * dfgV.x + material.specularF90 * dfgV.y;
	vec3 FssEss_L = material.specularColor * dfgL.x + material.specularF90 * dfgL.y;
	float Ess_V = dfgV.x + dfgV.y;
	float Ess_L = dfgL.x + dfgL.y;
	float Ems_V = 1.0 - Ess_V;
	float Ems_L = 1.0 - Ess_L;
	vec3 Favg = material.specularColor + ( 1.0 - material.specularColor ) * 0.047619;
	vec3 Fms = FssEss_V * FssEss_L * Favg / ( 1.0 - Ems_V * Ems_L * Favg * Favg + EPSILON );
	float compensationFactor = Ems_V * Ems_L;
	vec3 multiScatter = Fms * compensationFactor;
	return singleScatter + multiScatter;
}
#if NUM_RECT_AREA_LIGHTS > 0
	void RE_Direct_RectArea_Physical( const in RectAreaLight rectAreaLight, const in vec3 geometryPosition, const in vec3 geometryNormal, const in vec3 geometryViewDir, const in vec3 geometryClearcoatNormal, const in PhysicalMaterial material, inout ReflectedLight reflectedLight ) {
		vec3 normal = geometryNormal;
		vec3 viewDir = geometryViewDir;
		vec3 position = geometryPosition;
		vec3 lightPos = rectAreaLight.position;
		vec3 halfWidth = rectAreaLight.halfWidth;
		vec3 halfHeight = rectAreaLight.halfHeight;
		vec3 lightColor = rectAreaLight.color;
		float roughness = material.roughness;
		vec3 rectCoords[ 4 ];
		rectCoords[ 0 ] = lightPos + halfWidth - halfHeight;		rectCoords[ 1 ] = lightPos - halfWidth - halfHeight;
		rectCoords[ 2 ] = lightPos - halfWidth + halfHeight;
		rectCoords[ 3 ] = lightPos + halfWidth + halfHeight;
		vec2 uv = LTC_Uv( normal, viewDir, roughness );
		vec4 t1 = texture2D( ltc_1, uv );
		vec4 t2 = texture2D( ltc_2, uv );
		mat3 mInv = mat3(
			vec3( t1.x, 0, t1.y ),
			vec3(    0, 1,    0 ),
			vec3( t1.z, 0, t1.w )
		);
		vec3 fresnel = ( material.specularColor * t2.x + ( vec3( 1.0 ) - material.specularColor ) * t2.y );
		reflectedLight.directSpecular += lightColor * fresnel * LTC_Evaluate( normal, viewDir, position, mInv, rectCoords );
		reflectedLight.directDiffuse += lightColor * material.diffuseColor * LTC_Evaluate( normal, viewDir, position, mat3( 1.0 ), rectCoords );
	}
#endif
void RE_Direct_Physical( const in IncidentLight directLight, const in vec3 geometryPosition, const in vec3 geometryNormal, const in vec3 geometryViewDir, const in vec3 geometryClearcoatNormal, const in PhysicalMaterial material, inout ReflectedLight reflectedLight ) {
	float dotNL = saturate( dot( geometryNormal, directLight.direction ) );
	vec3 irradiance = dotNL * directLight.color;
	#ifdef USE_CLEARCOAT
		float dotNLcc = saturate( dot( geometryClearcoatNormal, directLight.direction ) );
		vec3 ccIrradiance = dotNLcc * directLight.color;
		clearcoatSpecularDirect += ccIrradiance * BRDF_GGX_Clearcoat( directLight.direction, geometryViewDir, geometryClearcoatNormal, material );
	#endif
	#ifdef USE_SHEEN
		sheenSpecularDirect += irradiance * BRDF_Sheen( directLight.direction, geometryViewDir, geometryNormal, material.sheenColor, material.sheenRoughness );
	#endif
	reflectedLight.directSpecular += irradiance * BRDF_GGX_Multiscatter( directLight.direction, geometryViewDir, geometryNormal, material );
	reflectedLight.directDiffuse += irradiance * BRDF_Lambert( material.diffuseColor );
}
void RE_IndirectDiffuse_Physical( const in vec3 irradiance, const in vec3 geometryPosition, const in vec3 geometryNormal, const in vec3 geometryViewDir, const in vec3 geometryClearcoatNormal, const in PhysicalMaterial material, inout ReflectedLight reflectedLight ) {
	reflectedLight.indirectDiffuse += irradiance * BRDF_Lambert( material.diffuseColor );
}
void RE_IndirectSpecular_Physical( const in vec3 radiance, const in vec3 irradiance, const in vec3 clearcoatRadiance, const in vec3 geometryPosition, const in vec3 geometryNormal, const in vec3 geometryViewDir, const in vec3 geometryClearcoatNormal, const in PhysicalMaterial material, inout ReflectedLight reflectedLight) {
	#ifdef USE_CLEARCOAT
		clearcoatSpecularIndirect += clearcoatRadiance * EnvironmentBRDF( geometryClearcoatNormal, geometryViewDir, material.clearcoatF0, material.clearcoatF90, material.clearcoatRoughness );
	#endif
	#ifdef USE_SHEEN
		sheenSpecularIndirect += irradiance * material.sheenColor * IBLSheenBRDF( geometryNormal, geometryViewDir, material.sheenRoughness );
	#endif
	vec3 singleScattering = vec3( 0.0 );
	vec3 multiScattering = vec3( 0.0 );
	vec3 cosineWeightedIrradiance = irradiance * RECIPROCAL_PI;
	#ifdef USE_IRIDESCENCE
		computeMultiscatteringIridescence( geometryNormal, geometryViewDir, material.specularColor, material.specularF90, material.iridescence, material.iridescenceFresnel, material.roughness, singleScattering, multiScattering );
	#else
		computeMultiscattering( geometryNormal, geometryViewDir, material.specularColor, material.specularF90, material.roughness, singleScattering, multiScattering );
	#endif
	vec3 totalScattering = singleScattering + multiScattering;
	vec3 diffuse = material.diffuseColor * ( 1.0 - max( max( totalScattering.r, totalScattering.g ), totalScattering.b ) );
	reflectedLight.indirectSpecular += radiance * singleScattering;
	reflectedLight.indirectSpecular += multiScattering * cosineWeightedIrradiance;
	reflectedLight.indirectDiffuse += diffuse * cosineWeightedIrradiance;
}
#define RE_Direct				RE_Direct_Physical
#define RE_Direct_RectArea		RE_Direct_RectArea_Physical
#define RE_IndirectDiffuse		RE_IndirectDiffuse_Physical
#define RE_IndirectSpecular		RE_IndirectSpecular_Physical
float computeSpecularOcclusion( const in float dotNV, const in float ambientOcclusion, const in float roughness ) {
	return saturate( pow( dotNV + ambientOcclusion, exp2( - 16.0 * roughness - 1.0 ) ) - 1.0 + ambientOcclusion );
}`,cg=`
vec3 geometryPosition = - vViewPosition;
vec3 geometryNormal = normal;
vec3 geometryViewDir = ( isOrthographic ) ? vec3( 0, 0, 1 ) : normalize( vViewPosition );
vec3 geometryClearcoatNormal = vec3( 0.0 );
#ifdef USE_CLEARCOAT
	geometryClearcoatNormal = clearcoatNormal;
#endif
#ifdef USE_IRIDESCENCE
	float dotNVi = saturate( dot( normal, geometryViewDir ) );
	if ( material.iridescenceThickness == 0.0 ) {
		material.iridescence = 0.0;
	} else {
		material.iridescence = saturate( material.iridescence );
	}
	if ( material.iridescence > 0.0 ) {
		material.iridescenceFresnel = evalIridescence( 1.0, material.iridescenceIOR, dotNVi, material.iridescenceThickness, material.specularColor );
		material.iridescenceF0 = Schlick_to_F0( material.iridescenceFresnel, 1.0, dotNVi );
	}
#endif
IncidentLight directLight;
#if ( NUM_POINT_LIGHTS > 0 ) && defined( RE_Direct )
	PointLight pointLight;
	#if defined( USE_SHADOWMAP ) && NUM_POINT_LIGHT_SHADOWS > 0
	PointLightShadow pointLightShadow;
	#endif
	#pragma unroll_loop_start
	for ( int i = 0; i < NUM_POINT_LIGHTS; i ++ ) {
		pointLight = pointLights[ i ];
		getPointLightInfo( pointLight, geometryPosition, directLight );
		#if defined( USE_SHADOWMAP ) && ( UNROLLED_LOOP_INDEX < NUM_POINT_LIGHT_SHADOWS )
		pointLightShadow = pointLightShadows[ i ];
		directLight.color *= ( directLight.visible && receiveShadow ) ? getPointShadow( pointShadowMap[ i ], pointLightShadow.shadowMapSize, pointLightShadow.shadowIntensity, pointLightShadow.shadowBias, pointLightShadow.shadowRadius, vPointShadowCoord[ i ], pointLightShadow.shadowCameraNear, pointLightShadow.shadowCameraFar ) : 1.0;
		#endif
		RE_Direct( directLight, geometryPosition, geometryNormal, geometryViewDir, geometryClearcoatNormal, material, reflectedLight );
	}
	#pragma unroll_loop_end
#endif
#if ( NUM_SPOT_LIGHTS > 0 ) && defined( RE_Direct )
	SpotLight spotLight;
	vec4 spotColor;
	vec3 spotLightCoord;
	bool inSpotLightMap;
	#if defined( USE_SHADOWMAP ) && NUM_SPOT_LIGHT_SHADOWS > 0
	SpotLightShadow spotLightShadow;
	#endif
	#pragma unroll_loop_start
	for ( int i = 0; i < NUM_SPOT_LIGHTS; i ++ ) {
		spotLight = spotLights[ i ];
		getSpotLightInfo( spotLight, geometryPosition, directLight );
		#if ( UNROLLED_LOOP_INDEX < NUM_SPOT_LIGHT_SHADOWS_WITH_MAPS )
		#define SPOT_LIGHT_MAP_INDEX UNROLLED_LOOP_INDEX
		#elif ( UNROLLED_LOOP_INDEX < NUM_SPOT_LIGHT_SHADOWS )
		#define SPOT_LIGHT_MAP_INDEX NUM_SPOT_LIGHT_MAPS
		#else
		#define SPOT_LIGHT_MAP_INDEX ( UNROLLED_LOOP_INDEX - NUM_SPOT_LIGHT_SHADOWS + NUM_SPOT_LIGHT_SHADOWS_WITH_MAPS )
		#endif
		#if ( SPOT_LIGHT_MAP_INDEX < NUM_SPOT_LIGHT_MAPS )
			spotLightCoord = vSpotLightCoord[ i ].xyz / vSpotLightCoord[ i ].w;
			inSpotLightMap = all( lessThan( abs( spotLightCoord * 2. - 1. ), vec3( 1.0 ) ) );
			spotColor = texture2D( spotLightMap[ SPOT_LIGHT_MAP_INDEX ], spotLightCoord.xy );
			directLight.color = inSpotLightMap ? directLight.color * spotColor.rgb : directLight.color;
		#endif
		#undef SPOT_LIGHT_MAP_INDEX
		#if defined( USE_SHADOWMAP ) && ( UNROLLED_LOOP_INDEX < NUM_SPOT_LIGHT_SHADOWS )
		spotLightShadow = spotLightShadows[ i ];
		directLight.color *= ( directLight.visible && receiveShadow ) ? getShadow( spotShadowMap[ i ], spotLightShadow.shadowMapSize, spotLightShadow.shadowIntensity, spotLightShadow.shadowBias, spotLightShadow.shadowRadius, vSpotLightCoord[ i ] ) : 1.0;
		#endif
		RE_Direct( directLight, geometryPosition, geometryNormal, geometryViewDir, geometryClearcoatNormal, material, reflectedLight );
	}
	#pragma unroll_loop_end
#endif
#if ( NUM_DIR_LIGHTS > 0 ) && defined( RE_Direct )
	DirectionalLight directionalLight;
	#if defined( USE_SHADOWMAP ) && NUM_DIR_LIGHT_SHADOWS > 0
	DirectionalLightShadow directionalLightShadow;
	#endif
	#pragma unroll_loop_start
	for ( int i = 0; i < NUM_DIR_LIGHTS; i ++ ) {
		directionalLight = directionalLights[ i ];
		getDirectionalLightInfo( directionalLight, directLight );
		#if defined( USE_SHADOWMAP ) && ( UNROLLED_LOOP_INDEX < NUM_DIR_LIGHT_SHADOWS )
		directionalLightShadow = directionalLightShadows[ i ];
		directLight.color *= ( directLight.visible && receiveShadow ) ? getShadow( directionalShadowMap[ i ], directionalLightShadow.shadowMapSize, directionalLightShadow.shadowIntensity, directionalLightShadow.shadowBias, directionalLightShadow.shadowRadius, vDirectionalShadowCoord[ i ] ) : 1.0;
		#endif
		RE_Direct( directLight, geometryPosition, geometryNormal, geometryViewDir, geometryClearcoatNormal, material, reflectedLight );
	}
	#pragma unroll_loop_end
#endif
#if ( NUM_RECT_AREA_LIGHTS > 0 ) && defined( RE_Direct_RectArea )
	RectAreaLight rectAreaLight;
	#pragma unroll_loop_start
	for ( int i = 0; i < NUM_RECT_AREA_LIGHTS; i ++ ) {
		rectAreaLight = rectAreaLights[ i ];
		RE_Direct_RectArea( rectAreaLight, geometryPosition, geometryNormal, geometryViewDir, geometryClearcoatNormal, material, reflectedLight );
	}
	#pragma unroll_loop_end
#endif
#if defined( RE_IndirectDiffuse )
	vec3 iblIrradiance = vec3( 0.0 );
	vec3 irradiance = getAmbientLightIrradiance( ambientLightColor );
	#if defined( USE_LIGHT_PROBES )
		irradiance += getLightProbeIrradiance( lightProbe, geometryNormal );
	#endif
	#if ( NUM_HEMI_LIGHTS > 0 )
		#pragma unroll_loop_start
		for ( int i = 0; i < NUM_HEMI_LIGHTS; i ++ ) {
			irradiance += getHemisphereLightIrradiance( hemisphereLights[ i ], geometryNormal );
		}
		#pragma unroll_loop_end
	#endif
#endif
#if defined( RE_IndirectSpecular )
	vec3 radiance = vec3( 0.0 );
	vec3 clearcoatRadiance = vec3( 0.0 );
#endif`,lg=`#if defined( RE_IndirectDiffuse )
	#ifdef USE_LIGHTMAP
		vec4 lightMapTexel = texture2D( lightMap, vLightMapUv );
		vec3 lightMapIrradiance = lightMapTexel.rgb * lightMapIntensity;
		irradiance += lightMapIrradiance;
	#endif
	#if defined( USE_ENVMAP ) && defined( STANDARD ) && defined( ENVMAP_TYPE_CUBE_UV )
		iblIrradiance += getIBLIrradiance( geometryNormal );
	#endif
#endif
#if defined( USE_ENVMAP ) && defined( RE_IndirectSpecular )
	#ifdef USE_ANISOTROPY
		radiance += getIBLAnisotropyRadiance( geometryViewDir, geometryNormal, material.roughness, material.anisotropyB, material.anisotropy );
	#else
		radiance += getIBLRadiance( geometryViewDir, geometryNormal, material.roughness );
	#endif
	#ifdef USE_CLEARCOAT
		clearcoatRadiance += getIBLRadiance( geometryViewDir, geometryClearcoatNormal, material.clearcoatRoughness );
	#endif
#endif`,ug=`#if defined( RE_IndirectDiffuse )
	RE_IndirectDiffuse( irradiance, geometryPosition, geometryNormal, geometryViewDir, geometryClearcoatNormal, material, reflectedLight );
#endif
#if defined( RE_IndirectSpecular )
	RE_IndirectSpecular( radiance, iblIrradiance, clearcoatRadiance, geometryPosition, geometryNormal, geometryViewDir, geometryClearcoatNormal, material, reflectedLight );
#endif`,hg=`#if defined( USE_LOGARITHMIC_DEPTH_BUFFER )
	gl_FragDepth = vIsPerspective == 0.0 ? gl_FragCoord.z : log2( vFragDepth ) * logDepthBufFC * 0.5;
#endif`,fg=`#if defined( USE_LOGARITHMIC_DEPTH_BUFFER )
	uniform float logDepthBufFC;
	varying float vFragDepth;
	varying float vIsPerspective;
#endif`,dg=`#ifdef USE_LOGARITHMIC_DEPTH_BUFFER
	varying float vFragDepth;
	varying float vIsPerspective;
#endif`,pg=`#ifdef USE_LOGARITHMIC_DEPTH_BUFFER
	vFragDepth = 1.0 + gl_Position.w;
	vIsPerspective = float( isPerspectiveMatrix( projectionMatrix ) );
#endif`,mg=`#ifdef USE_MAP
	vec4 sampledDiffuseColor = texture2D( map, vMapUv );
	#ifdef DECODE_VIDEO_TEXTURE
		sampledDiffuseColor = sRGBTransferEOTF( sampledDiffuseColor );
	#endif
	diffuseColor *= sampledDiffuseColor;
#endif`,gg=`#ifdef USE_MAP
	uniform sampler2D map;
#endif`,xg=`#if defined( USE_MAP ) || defined( USE_ALPHAMAP )
	#if defined( USE_POINTS_UV )
		vec2 uv = vUv;
	#else
		vec2 uv = ( uvTransform * vec3( gl_PointCoord.x, 1.0 - gl_PointCoord.y, 1 ) ).xy;
	#endif
#endif
#ifdef USE_MAP
	diffuseColor *= texture2D( map, uv );
#endif
#ifdef USE_ALPHAMAP
	diffuseColor.a *= texture2D( alphaMap, uv ).g;
#endif`,vg=`#if defined( USE_POINTS_UV )
	varying vec2 vUv;
#else
	#if defined( USE_MAP ) || defined( USE_ALPHAMAP )
		uniform mat3 uvTransform;
	#endif
#endif
#ifdef USE_MAP
	uniform sampler2D map;
#endif
#ifdef USE_ALPHAMAP
	uniform sampler2D alphaMap;
#endif`,_g=`float metalnessFactor = metalness;
#ifdef USE_METALNESSMAP
	vec4 texelMetalness = texture2D( metalnessMap, vMetalnessMapUv );
	metalnessFactor *= texelMetalness.b;
#endif`,yg=`#ifdef USE_METALNESSMAP
	uniform sampler2D metalnessMap;
#endif`,bg=`#ifdef USE_INSTANCING_MORPH
	float morphTargetInfluences[ MORPHTARGETS_COUNT ];
	float morphTargetBaseInfluence = texelFetch( morphTexture, ivec2( 0, gl_InstanceID ), 0 ).r;
	for ( int i = 0; i < MORPHTARGETS_COUNT; i ++ ) {
		morphTargetInfluences[i] =  texelFetch( morphTexture, ivec2( i + 1, gl_InstanceID ), 0 ).r;
	}
#endif`,Sg=`#if defined( USE_MORPHCOLORS )
	vColor *= morphTargetBaseInfluence;
	for ( int i = 0; i < MORPHTARGETS_COUNT; i ++ ) {
		#if defined( USE_COLOR_ALPHA )
			if ( morphTargetInfluences[ i ] != 0.0 ) vColor += getMorph( gl_VertexID, i, 2 ) * morphTargetInfluences[ i ];
		#elif defined( USE_COLOR )
			if ( morphTargetInfluences[ i ] != 0.0 ) vColor += getMorph( gl_VertexID, i, 2 ).rgb * morphTargetInfluences[ i ];
		#endif
	}
#endif`,Mg=`#ifdef USE_MORPHNORMALS
	objectNormal *= morphTargetBaseInfluence;
	for ( int i = 0; i < MORPHTARGETS_COUNT; i ++ ) {
		if ( morphTargetInfluences[ i ] != 0.0 ) objectNormal += getMorph( gl_VertexID, i, 1 ).xyz * morphTargetInfluences[ i ];
	}
#endif`,Tg=`#ifdef USE_MORPHTARGETS
	#ifndef USE_INSTANCING_MORPH
		uniform float morphTargetBaseInfluence;
		uniform float morphTargetInfluences[ MORPHTARGETS_COUNT ];
	#endif
	uniform sampler2DArray morphTargetsTexture;
	uniform ivec2 morphTargetsTextureSize;
	vec4 getMorph( const in int vertexIndex, const in int morphTargetIndex, const in int offset ) {
		int texelIndex = vertexIndex * MORPHTARGETS_TEXTURE_STRIDE + offset;
		int y = texelIndex / morphTargetsTextureSize.x;
		int x = texelIndex - y * morphTargetsTextureSize.x;
		ivec3 morphUV = ivec3( x, y, morphTargetIndex );
		return texelFetch( morphTargetsTexture, morphUV, 0 );
	}
#endif`,wg=`#ifdef USE_MORPHTARGETS
	transformed *= morphTargetBaseInfluence;
	for ( int i = 0; i < MORPHTARGETS_COUNT; i ++ ) {
		if ( morphTargetInfluences[ i ] != 0.0 ) transformed += getMorph( gl_VertexID, i, 0 ).xyz * morphTargetInfluences[ i ];
	}
#endif`,Ag=`float faceDirection = gl_FrontFacing ? 1.0 : - 1.0;
#ifdef FLAT_SHADED
	vec3 fdx = dFdx( vViewPosition );
	vec3 fdy = dFdy( vViewPosition );
	vec3 normal = normalize( cross( fdx, fdy ) );
#else
	vec3 normal = normalize( vNormal );
	#ifdef DOUBLE_SIDED
		normal *= faceDirection;
	#endif
#endif
#if defined( USE_NORMALMAP_TANGENTSPACE ) || defined( USE_CLEARCOAT_NORMALMAP ) || defined( USE_ANISOTROPY )
	#ifdef USE_TANGENT
		mat3 tbn = mat3( normalize( vTangent ), normalize( vBitangent ), normal );
	#else
		mat3 tbn = getTangentFrame( - vViewPosition, normal,
		#if defined( USE_NORMALMAP )
			vNormalMapUv
		#elif defined( USE_CLEARCOAT_NORMALMAP )
			vClearcoatNormalMapUv
		#else
			vUv
		#endif
		);
	#endif
	#if defined( DOUBLE_SIDED ) && ! defined( FLAT_SHADED )
		tbn[0] *= faceDirection;
		tbn[1] *= faceDirection;
	#endif
#endif
#ifdef USE_CLEARCOAT_NORMALMAP
	#ifdef USE_TANGENT
		mat3 tbn2 = mat3( normalize( vTangent ), normalize( vBitangent ), normal );
	#else
		mat3 tbn2 = getTangentFrame( - vViewPosition, normal, vClearcoatNormalMapUv );
	#endif
	#if defined( DOUBLE_SIDED ) && ! defined( FLAT_SHADED )
		tbn2[0] *= faceDirection;
		tbn2[1] *= faceDirection;
	#endif
#endif
vec3 nonPerturbedNormal = normal;`,Eg=`#ifdef USE_NORMALMAP_OBJECTSPACE
	normal = texture2D( normalMap, vNormalMapUv ).xyz * 2.0 - 1.0;
	#ifdef FLIP_SIDED
		normal = - normal;
	#endif
	#ifdef DOUBLE_SIDED
		normal = normal * faceDirection;
	#endif
	normal = normalize( normalMatrix * normal );
#elif defined( USE_NORMALMAP_TANGENTSPACE )
	vec3 mapN = texture2D( normalMap, vNormalMapUv ).xyz * 2.0 - 1.0;
	mapN.xy *= normalScale;
	normal = normalize( tbn * mapN );
#elif defined( USE_BUMPMAP )
	normal = perturbNormalArb( - vViewPosition, normal, dHdxy_fwd(), faceDirection );
#endif`,Cg=`#ifndef FLAT_SHADED
	varying vec3 vNormal;
	#ifdef USE_TANGENT
		varying vec3 vTangent;
		varying vec3 vBitangent;
	#endif
#endif`,Rg=`#ifndef FLAT_SHADED
	varying vec3 vNormal;
	#ifdef USE_TANGENT
		varying vec3 vTangent;
		varying vec3 vBitangent;
	#endif
#endif`,Ig=`#ifndef FLAT_SHADED
	vNormal = normalize( transformedNormal );
	#ifdef USE_TANGENT
		vTangent = normalize( transformedTangent );
		vBitangent = normalize( cross( vNormal, vTangent ) * tangent.w );
	#endif
#endif`,Pg=`#ifdef USE_NORMALMAP
	uniform sampler2D normalMap;
	uniform vec2 normalScale;
#endif
#ifdef USE_NORMALMAP_OBJECTSPACE
	uniform mat3 normalMatrix;
#endif
#if ! defined ( USE_TANGENT ) && ( defined ( USE_NORMALMAP_TANGENTSPACE ) || defined ( USE_CLEARCOAT_NORMALMAP ) || defined( USE_ANISOTROPY ) )
	mat3 getTangentFrame( vec3 eye_pos, vec3 surf_norm, vec2 uv ) {
		vec3 q0 = dFdx( eye_pos.xyz );
		vec3 q1 = dFdy( eye_pos.xyz );
		vec2 st0 = dFdx( uv.st );
		vec2 st1 = dFdy( uv.st );
		vec3 N = surf_norm;
		vec3 q1perp = cross( q1, N );
		vec3 q0perp = cross( N, q0 );
		vec3 T = q1perp * st0.x + q0perp * st1.x;
		vec3 B = q1perp * st0.y + q0perp * st1.y;
		float det = max( dot( T, T ), dot( B, B ) );
		float scale = ( det == 0.0 ) ? 0.0 : inversesqrt( det );
		return mat3( T * scale, B * scale, N );
	}
#endif`,Dg=`#ifdef USE_CLEARCOAT
	vec3 clearcoatNormal = nonPerturbedNormal;
#endif`,Fg=`#ifdef USE_CLEARCOAT_NORMALMAP
	vec3 clearcoatMapN = texture2D( clearcoatNormalMap, vClearcoatNormalMapUv ).xyz * 2.0 - 1.0;
	clearcoatMapN.xy *= clearcoatNormalScale;
	clearcoatNormal = normalize( tbn2 * clearcoatMapN );
#endif`,Lg=`#ifdef USE_CLEARCOATMAP
	uniform sampler2D clearcoatMap;
#endif
#ifdef USE_CLEARCOAT_NORMALMAP
	uniform sampler2D clearcoatNormalMap;
	uniform vec2 clearcoatNormalScale;
#endif
#ifdef USE_CLEARCOAT_ROUGHNESSMAP
	uniform sampler2D clearcoatRoughnessMap;
#endif`,Ng=`#ifdef USE_IRIDESCENCEMAP
	uniform sampler2D iridescenceMap;
#endif
#ifdef USE_IRIDESCENCE_THICKNESSMAP
	uniform sampler2D iridescenceThicknessMap;
#endif`,Ug=`#ifdef OPAQUE
diffuseColor.a = 1.0;
#endif
#ifdef USE_TRANSMISSION
diffuseColor.a *= material.transmissionAlpha;
#endif
gl_FragColor = vec4( outgoingLight, diffuseColor.a );`,Bg=`vec3 packNormalToRGB( const in vec3 normal ) {
	return normalize( normal ) * 0.5 + 0.5;
}
vec3 unpackRGBToNormal( const in vec3 rgb ) {
	return 2.0 * rgb.xyz - 1.0;
}
const float PackUpscale = 256. / 255.;const float UnpackDownscale = 255. / 256.;const float ShiftRight8 = 1. / 256.;
const float Inv255 = 1. / 255.;
const vec4 PackFactors = vec4( 1.0, 256.0, 256.0 * 256.0, 256.0 * 256.0 * 256.0 );
const vec2 UnpackFactors2 = vec2( UnpackDownscale, 1.0 / PackFactors.g );
const vec3 UnpackFactors3 = vec3( UnpackDownscale / PackFactors.rg, 1.0 / PackFactors.b );
const vec4 UnpackFactors4 = vec4( UnpackDownscale / PackFactors.rgb, 1.0 / PackFactors.a );
vec4 packDepthToRGBA( const in float v ) {
	if( v <= 0.0 )
		return vec4( 0., 0., 0., 0. );
	if( v >= 1.0 )
		return vec4( 1., 1., 1., 1. );
	float vuf;
	float af = modf( v * PackFactors.a, vuf );
	float bf = modf( vuf * ShiftRight8, vuf );
	float gf = modf( vuf * ShiftRight8, vuf );
	return vec4( vuf * Inv255, gf * PackUpscale, bf * PackUpscale, af );
}
vec3 packDepthToRGB( const in float v ) {
	if( v <= 0.0 )
		return vec3( 0., 0., 0. );
	if( v >= 1.0 )
		return vec3( 1., 1., 1. );
	float vuf;
	float bf = modf( v * PackFactors.b, vuf );
	float gf = modf( vuf * ShiftRight8, vuf );
	return vec3( vuf * Inv255, gf * PackUpscale, bf );
}
vec2 packDepthToRG( const in float v ) {
	if( v <= 0.0 )
		return vec2( 0., 0. );
	if( v >= 1.0 )
		return vec2( 1., 1. );
	float vuf;
	float gf = modf( v * 256., vuf );
	return vec2( vuf * Inv255, gf );
}
float unpackRGBAToDepth( const in vec4 v ) {
	return dot( v, UnpackFactors4 );
}
float unpackRGBToDepth( const in vec3 v ) {
	return dot( v, UnpackFactors3 );
}
float unpackRGToDepth( const in vec2 v ) {
	return v.r * UnpackFactors2.r + v.g * UnpackFactors2.g;
}
vec4 pack2HalfToRGBA( const in vec2 v ) {
	vec4 r = vec4( v.x, fract( v.x * 255.0 ), v.y, fract( v.y * 255.0 ) );
	return vec4( r.x - r.y / 255.0, r.y, r.z - r.w / 255.0, r.w );
}
vec2 unpackRGBATo2Half( const in vec4 v ) {
	return vec2( v.x + ( v.y / 255.0 ), v.z + ( v.w / 255.0 ) );
}
float viewZToOrthographicDepth( const in float viewZ, const in float near, const in float far ) {
	return ( viewZ + near ) / ( near - far );
}
float orthographicDepthToViewZ( const in float depth, const in float near, const in float far ) {
	return depth * ( near - far ) - near;
}
float viewZToPerspectiveDepth( const in float viewZ, const in float near, const in float far ) {
	return ( ( near + viewZ ) * far ) / ( ( far - near ) * viewZ );
}
float perspectiveDepthToViewZ( const in float depth, const in float near, const in float far ) {
	return ( near * far ) / ( ( far - near ) * depth - far );
}`,Og=`#ifdef PREMULTIPLIED_ALPHA
	gl_FragColor.rgb *= gl_FragColor.a;
#endif`,zg=`vec4 mvPosition = vec4( transformed, 1.0 );
#ifdef USE_BATCHING
	mvPosition = batchingMatrix * mvPosition;
#endif
#ifdef USE_INSTANCING
	mvPosition = instanceMatrix * mvPosition;
#endif
mvPosition = modelViewMatrix * mvPosition;
gl_Position = projectionMatrix * mvPosition;`,kg=`#ifdef DITHERING
	gl_FragColor.rgb = dithering( gl_FragColor.rgb );
#endif`,Vg=`#ifdef DITHERING
	vec3 dithering( vec3 color ) {
		float grid_position = rand( gl_FragCoord.xy );
		vec3 dither_shift_RGB = vec3( 0.25 / 255.0, -0.25 / 255.0, 0.25 / 255.0 );
		dither_shift_RGB = mix( 2.0 * dither_shift_RGB, -2.0 * dither_shift_RGB, grid_position );
		return color + dither_shift_RGB;
	}
#endif`,Hg=`float roughnessFactor = roughness;
#ifdef USE_ROUGHNESSMAP
	vec4 texelRoughness = texture2D( roughnessMap, vRoughnessMapUv );
	roughnessFactor *= texelRoughness.g;
#endif`,Gg=`#ifdef USE_ROUGHNESSMAP
	uniform sampler2D roughnessMap;
#endif`,Wg=`#if NUM_SPOT_LIGHT_COORDS > 0
	varying vec4 vSpotLightCoord[ NUM_SPOT_LIGHT_COORDS ];
#endif
#if NUM_SPOT_LIGHT_MAPS > 0
	uniform sampler2D spotLightMap[ NUM_SPOT_LIGHT_MAPS ];
#endif
#ifdef USE_SHADOWMAP
	#if NUM_DIR_LIGHT_SHADOWS > 0
		uniform sampler2D directionalShadowMap[ NUM_DIR_LIGHT_SHADOWS ];
		varying vec4 vDirectionalShadowCoord[ NUM_DIR_LIGHT_SHADOWS ];
		struct DirectionalLightShadow {
			float shadowIntensity;
			float shadowBias;
			float shadowNormalBias;
			float shadowRadius;
			vec2 shadowMapSize;
		};
		uniform DirectionalLightShadow directionalLightShadows[ NUM_DIR_LIGHT_SHADOWS ];
	#endif
	#if NUM_SPOT_LIGHT_SHADOWS > 0
		uniform sampler2D spotShadowMap[ NUM_SPOT_LIGHT_SHADOWS ];
		struct SpotLightShadow {
			float shadowIntensity;
			float shadowBias;
			float shadowNormalBias;
			float shadowRadius;
			vec2 shadowMapSize;
		};
		uniform SpotLightShadow spotLightShadows[ NUM_SPOT_LIGHT_SHADOWS ];
	#endif
	#if NUM_POINT_LIGHT_SHADOWS > 0
		uniform sampler2D pointShadowMap[ NUM_POINT_LIGHT_SHADOWS ];
		varying vec4 vPointShadowCoord[ NUM_POINT_LIGHT_SHADOWS ];
		struct PointLightShadow {
			float shadowIntensity;
			float shadowBias;
			float shadowNormalBias;
			float shadowRadius;
			vec2 shadowMapSize;
			float shadowCameraNear;
			float shadowCameraFar;
		};
		uniform PointLightShadow pointLightShadows[ NUM_POINT_LIGHT_SHADOWS ];
	#endif
	float texture2DCompare( sampler2D depths, vec2 uv, float compare ) {
		float depth = unpackRGBAToDepth( texture2D( depths, uv ) );
		#ifdef USE_REVERSED_DEPTH_BUFFER
			return step( depth, compare );
		#else
			return step( compare, depth );
		#endif
	}
	vec2 texture2DDistribution( sampler2D shadow, vec2 uv ) {
		return unpackRGBATo2Half( texture2D( shadow, uv ) );
	}
	float VSMShadow( sampler2D shadow, vec2 uv, float compare ) {
		float occlusion = 1.0;
		vec2 distribution = texture2DDistribution( shadow, uv );
		#ifdef USE_REVERSED_DEPTH_BUFFER
			float hard_shadow = step( distribution.x, compare );
		#else
			float hard_shadow = step( compare, distribution.x );
		#endif
		if ( hard_shadow != 1.0 ) {
			float distance = compare - distribution.x;
			float variance = max( 0.00000, distribution.y * distribution.y );
			float softness_probability = variance / (variance + distance * distance );			softness_probability = clamp( ( softness_probability - 0.3 ) / ( 0.95 - 0.3 ), 0.0, 1.0 );			occlusion = clamp( max( hard_shadow, softness_probability ), 0.0, 1.0 );
		}
		return occlusion;
	}
	float getShadow( sampler2D shadowMap, vec2 shadowMapSize, float shadowIntensity, float shadowBias, float shadowRadius, vec4 shadowCoord ) {
		float shadow = 1.0;
		shadowCoord.xyz /= shadowCoord.w;
		shadowCoord.z += shadowBias;
		bool inFrustum = shadowCoord.x >= 0.0 && shadowCoord.x <= 1.0 && shadowCoord.y >= 0.0 && shadowCoord.y <= 1.0;
		bool frustumTest = inFrustum && shadowCoord.z <= 1.0;
		if ( frustumTest ) {
		#if defined( SHADOWMAP_TYPE_PCF )
			vec2 texelSize = vec2( 1.0 ) / shadowMapSize;
			float dx0 = - texelSize.x * shadowRadius;
			float dy0 = - texelSize.y * shadowRadius;
			float dx1 = + texelSize.x * shadowRadius;
			float dy1 = + texelSize.y * shadowRadius;
			float dx2 = dx0 / 2.0;
			float dy2 = dy0 / 2.0;
			float dx3 = dx1 / 2.0;
			float dy3 = dy1 / 2.0;
			shadow = (
				texture2DCompare( shadowMap, shadowCoord.xy + vec2( dx0, dy0 ), shadowCoord.z ) +
				texture2DCompare( shadowMap, shadowCoord.xy + vec2( 0.0, dy0 ), shadowCoord.z ) +
				texture2DCompare( shadowMap, shadowCoord.xy + vec2( dx1, dy0 ), shadowCoord.z ) +
				texture2DCompare( shadowMap, shadowCoord.xy + vec2( dx2, dy2 ), shadowCoord.z ) +
				texture2DCompare( shadowMap, shadowCoord.xy + vec2( 0.0, dy2 ), shadowCoord.z ) +
				texture2DCompare( shadowMap, shadowCoord.xy + vec2( dx3, dy2 ), shadowCoord.z ) +
				texture2DCompare( shadowMap, shadowCoord.xy + vec2( dx0, 0.0 ), shadowCoord.z ) +
				texture2DCompare( shadowMap, shadowCoord.xy + vec2( dx2, 0.0 ), shadowCoord.z ) +
				texture2DCompare( shadowMap, shadowCoord.xy, shadowCoord.z ) +
				texture2DCompare( shadowMap, shadowCoord.xy + vec2( dx3, 0.0 ), shadowCoord.z ) +
				texture2DCompare( shadowMap, shadowCoord.xy + vec2( dx1, 0.0 ), shadowCoord.z ) +
				texture2DCompare( shadowMap, shadowCoord.xy + vec2( dx2, dy3 ), shadowCoord.z ) +
				texture2DCompare( shadowMap, shadowCoord.xy + vec2( 0.0, dy3 ), shadowCoord.z ) +
				texture2DCompare( shadowMap, shadowCoord.xy + vec2( dx3, dy3 ), shadowCoord.z ) +
				texture2DCompare( shadowMap, shadowCoord.xy + vec2( dx0, dy1 ), shadowCoord.z ) +
				texture2DCompare( shadowMap, shadowCoord.xy + vec2( 0.0, dy1 ), shadowCoord.z ) +
				texture2DCompare( shadowMap, shadowCoord.xy + vec2( dx1, dy1 ), shadowCoord.z )
			) * ( 1.0 / 17.0 );
		#elif defined( SHADOWMAP_TYPE_PCF_SOFT )
			vec2 texelSize = vec2( 1.0 ) / shadowMapSize;
			float dx = texelSize.x;
			float dy = texelSize.y;
			vec2 uv = shadowCoord.xy;
			vec2 f = fract( uv * shadowMapSize + 0.5 );
			uv -= f * texelSize;
			shadow = (
				texture2DCompare( shadowMap, uv, shadowCoord.z ) +
				texture2DCompare( shadowMap, uv + vec2( dx, 0.0 ), shadowCoord.z ) +
				texture2DCompare( shadowMap, uv + vec2( 0.0, dy ), shadowCoord.z ) +
				texture2DCompare( shadowMap, uv + texelSize, shadowCoord.z ) +
				mix( texture2DCompare( shadowMap, uv + vec2( -dx, 0.0 ), shadowCoord.z ),
					 texture2DCompare( shadowMap, uv + vec2( 2.0 * dx, 0.0 ), shadowCoord.z ),
					 f.x ) +
				mix( texture2DCompare( shadowMap, uv + vec2( -dx, dy ), shadowCoord.z ),
					 texture2DCompare( shadowMap, uv + vec2( 2.0 * dx, dy ), shadowCoord.z ),
					 f.x ) +
				mix( texture2DCompare( shadowMap, uv + vec2( 0.0, -dy ), shadowCoord.z ),
					 texture2DCompare( shadowMap, uv + vec2( 0.0, 2.0 * dy ), shadowCoord.z ),
					 f.y ) +
				mix( texture2DCompare( shadowMap, uv + vec2( dx, -dy ), shadowCoord.z ),
					 texture2DCompare( shadowMap, uv + vec2( dx, 2.0 * dy ), shadowCoord.z ),
					 f.y ) +
				mix( mix( texture2DCompare( shadowMap, uv + vec2( -dx, -dy ), shadowCoord.z ),
						  texture2DCompare( shadowMap, uv + vec2( 2.0 * dx, -dy ), shadowCoord.z ),
						  f.x ),
					 mix( texture2DCompare( shadowMap, uv + vec2( -dx, 2.0 * dy ), shadowCoord.z ),
						  texture2DCompare( shadowMap, uv + vec2( 2.0 * dx, 2.0 * dy ), shadowCoord.z ),
						  f.x ),
					 f.y )
			) * ( 1.0 / 9.0 );
		#elif defined( SHADOWMAP_TYPE_VSM )
			shadow = VSMShadow( shadowMap, shadowCoord.xy, shadowCoord.z );
		#else
			shadow = texture2DCompare( shadowMap, shadowCoord.xy, shadowCoord.z );
		#endif
		}
		return mix( 1.0, shadow, shadowIntensity );
	}
	vec2 cubeToUV( vec3 v, float texelSizeY ) {
		vec3 absV = abs( v );
		float scaleToCube = 1.0 / max( absV.x, max( absV.y, absV.z ) );
		absV *= scaleToCube;
		v *= scaleToCube * ( 1.0 - 2.0 * texelSizeY );
		vec2 planar = v.xy;
		float almostATexel = 1.5 * texelSizeY;
		float almostOne = 1.0 - almostATexel;
		if ( absV.z >= almostOne ) {
			if ( v.z > 0.0 )
				planar.x = 4.0 - v.x;
		} else if ( absV.x >= almostOne ) {
			float signX = sign( v.x );
			planar.x = v.z * signX + 2.0 * signX;
		} else if ( absV.y >= almostOne ) {
			float signY = sign( v.y );
			planar.x = v.x + 2.0 * signY + 2.0;
			planar.y = v.z * signY - 2.0;
		}
		return vec2( 0.125, 0.25 ) * planar + vec2( 0.375, 0.75 );
	}
	float getPointShadow( sampler2D shadowMap, vec2 shadowMapSize, float shadowIntensity, float shadowBias, float shadowRadius, vec4 shadowCoord, float shadowCameraNear, float shadowCameraFar ) {
		float shadow = 1.0;
		vec3 lightToPosition = shadowCoord.xyz;
		
		float lightToPositionLength = length( lightToPosition );
		if ( lightToPositionLength - shadowCameraFar <= 0.0 && lightToPositionLength - shadowCameraNear >= 0.0 ) {
			float dp = ( lightToPositionLength - shadowCameraNear ) / ( shadowCameraFar - shadowCameraNear );			dp += shadowBias;
			vec3 bd3D = normalize( lightToPosition );
			vec2 texelSize = vec2( 1.0 ) / ( shadowMapSize * vec2( 4.0, 2.0 ) );
			#if defined( SHADOWMAP_TYPE_PCF ) || defined( SHADOWMAP_TYPE_PCF_SOFT ) || defined( SHADOWMAP_TYPE_VSM )
				vec2 offset = vec2( - 1, 1 ) * shadowRadius * texelSize.y;
				shadow = (
					texture2DCompare( shadowMap, cubeToUV( bd3D + offset.xyy, texelSize.y ), dp ) +
					texture2DCompare( shadowMap, cubeToUV( bd3D + offset.yyy, texelSize.y ), dp ) +
					texture2DCompare( shadowMap, cubeToUV( bd3D + offset.xyx, texelSize.y ), dp ) +
					texture2DCompare( shadowMap, cubeToUV( bd3D + offset.yyx, texelSize.y ), dp ) +
					texture2DCompare( shadowMap, cubeToUV( bd3D, texelSize.y ), dp ) +
					texture2DCompare( shadowMap, cubeToUV( bd3D + offset.xxy, texelSize.y ), dp ) +
					texture2DCompare( shadowMap, cubeToUV( bd3D + offset.yxy, texelSize.y ), dp ) +
					texture2DCompare( shadowMap, cubeToUV( bd3D + offset.xxx, texelSize.y ), dp ) +
					texture2DCompare( shadowMap, cubeToUV( bd3D + offset.yxx, texelSize.y ), dp )
				) * ( 1.0 / 9.0 );
			#else
				shadow = texture2DCompare( shadowMap, cubeToUV( bd3D, texelSize.y ), dp );
			#endif
		}
		return mix( 1.0, shadow, shadowIntensity );
	}
#endif`,Xg=`#if NUM_SPOT_LIGHT_COORDS > 0
	uniform mat4 spotLightMatrix[ NUM_SPOT_LIGHT_COORDS ];
	varying vec4 vSpotLightCoord[ NUM_SPOT_LIGHT_COORDS ];
#endif
#ifdef USE_SHADOWMAP
	#if NUM_DIR_LIGHT_SHADOWS > 0
		uniform mat4 directionalShadowMatrix[ NUM_DIR_LIGHT_SHADOWS ];
		varying vec4 vDirectionalShadowCoord[ NUM_DIR_LIGHT_SHADOWS ];
		struct DirectionalLightShadow {
			float shadowIntensity;
			float shadowBias;
			float shadowNormalBias;
			float shadowRadius;
			vec2 shadowMapSize;
		};
		uniform DirectionalLightShadow directionalLightShadows[ NUM_DIR_LIGHT_SHADOWS ];
	#endif
	#if NUM_SPOT_LIGHT_SHADOWS > 0
		struct SpotLightShadow {
			float shadowIntensity;
			float shadowBias;
			float shadowNormalBias;
			float shadowRadius;
			vec2 shadowMapSize;
		};
		uniform SpotLightShadow spotLightShadows[ NUM_SPOT_LIGHT_SHADOWS ];
	#endif
	#if NUM_POINT_LIGHT_SHADOWS > 0
		uniform mat4 pointShadowMatrix[ NUM_POINT_LIGHT_SHADOWS ];
		varying vec4 vPointShadowCoord[ NUM_POINT_LIGHT_SHADOWS ];
		struct PointLightShadow {
			float shadowIntensity;
			float shadowBias;
			float shadowNormalBias;
			float shadowRadius;
			vec2 shadowMapSize;
			float shadowCameraNear;
			float shadowCameraFar;
		};
		uniform PointLightShadow pointLightShadows[ NUM_POINT_LIGHT_SHADOWS ];
	#endif
#endif`,qg=`#if ( defined( USE_SHADOWMAP ) && ( NUM_DIR_LIGHT_SHADOWS > 0 || NUM_POINT_LIGHT_SHADOWS > 0 ) ) || ( NUM_SPOT_LIGHT_COORDS > 0 )
	vec3 shadowWorldNormal = inverseTransformDirection( transformedNormal, viewMatrix );
	vec4 shadowWorldPosition;
#endif
#if defined( USE_SHADOWMAP )
	#if NUM_DIR_LIGHT_SHADOWS > 0
		#pragma unroll_loop_start
		for ( int i = 0; i < NUM_DIR_LIGHT_SHADOWS; i ++ ) {
			shadowWorldPosition = worldPosition + vec4( shadowWorldNormal * directionalLightShadows[ i ].shadowNormalBias, 0 );
			vDirectionalShadowCoord[ i ] = directionalShadowMatrix[ i ] * shadowWorldPosition;
		}
		#pragma unroll_loop_end
	#endif
	#if NUM_POINT_LIGHT_SHADOWS > 0
		#pragma unroll_loop_start
		for ( int i = 0; i < NUM_POINT_LIGHT_SHADOWS; i ++ ) {
			shadowWorldPosition = worldPosition + vec4( shadowWorldNormal * pointLightShadows[ i ].shadowNormalBias, 0 );
			vPointShadowCoord[ i ] = pointShadowMatrix[ i ] * shadowWorldPosition;
		}
		#pragma unroll_loop_end
	#endif
#endif
#if NUM_SPOT_LIGHT_COORDS > 0
	#pragma unroll_loop_start
	for ( int i = 0; i < NUM_SPOT_LIGHT_COORDS; i ++ ) {
		shadowWorldPosition = worldPosition;
		#if ( defined( USE_SHADOWMAP ) && UNROLLED_LOOP_INDEX < NUM_SPOT_LIGHT_SHADOWS )
			shadowWorldPosition.xyz += shadowWorldNormal * spotLightShadows[ i ].shadowNormalBias;
		#endif
		vSpotLightCoord[ i ] = spotLightMatrix[ i ] * shadowWorldPosition;
	}
	#pragma unroll_loop_end
#endif`,Yg=`float getShadowMask() {
	float shadow = 1.0;
	#ifdef USE_SHADOWMAP
	#if NUM_DIR_LIGHT_SHADOWS > 0
	DirectionalLightShadow directionalLight;
	#pragma unroll_loop_start
	for ( int i = 0; i < NUM_DIR_LIGHT_SHADOWS; i ++ ) {
		directionalLight = directionalLightShadows[ i ];
		shadow *= receiveShadow ? getShadow( directionalShadowMap[ i ], directionalLight.shadowMapSize, directionalLight.shadowIntensity, directionalLight.shadowBias, directionalLight.shadowRadius, vDirectionalShadowCoord[ i ] ) : 1.0;
	}
	#pragma unroll_loop_end
	#endif
	#if NUM_SPOT_LIGHT_SHADOWS > 0
	SpotLightShadow spotLight;
	#pragma unroll_loop_start
	for ( int i = 0; i < NUM_SPOT_LIGHT_SHADOWS; i ++ ) {
		spotLight = spotLightShadows[ i ];
		shadow *= receiveShadow ? getShadow( spotShadowMap[ i ], spotLight.shadowMapSize, spotLight.shadowIntensity, spotLight.shadowBias, spotLight.shadowRadius, vSpotLightCoord[ i ] ) : 1.0;
	}
	#pragma unroll_loop_end
	#endif
	#if NUM_POINT_LIGHT_SHADOWS > 0
	PointLightShadow pointLight;
	#pragma unroll_loop_start
	for ( int i = 0; i < NUM_POINT_LIGHT_SHADOWS; i ++ ) {
		pointLight = pointLightShadows[ i ];
		shadow *= receiveShadow ? getPointShadow( pointShadowMap[ i ], pointLight.shadowMapSize, pointLight.shadowIntensity, pointLight.shadowBias, pointLight.shadowRadius, vPointShadowCoord[ i ], pointLight.shadowCameraNear, pointLight.shadowCameraFar ) : 1.0;
	}
	#pragma unroll_loop_end
	#endif
	#endif
	return shadow;
}`,Zg=`#ifdef USE_SKINNING
	mat4 boneMatX = getBoneMatrix( skinIndex.x );
	mat4 boneMatY = getBoneMatrix( skinIndex.y );
	mat4 boneMatZ = getBoneMatrix( skinIndex.z );
	mat4 boneMatW = getBoneMatrix( skinIndex.w );
#endif`,$g=`#ifdef USE_SKINNING
	uniform mat4 bindMatrix;
	uniform mat4 bindMatrixInverse;
	uniform highp sampler2D boneTexture;
	mat4 getBoneMatrix( const in float i ) {
		int size = textureSize( boneTexture, 0 ).x;
		int j = int( i ) * 4;
		int x = j % size;
		int y = j / size;
		vec4 v1 = texelFetch( boneTexture, ivec2( x, y ), 0 );
		vec4 v2 = texelFetch( boneTexture, ivec2( x + 1, y ), 0 );
		vec4 v3 = texelFetch( boneTexture, ivec2( x + 2, y ), 0 );
		vec4 v4 = texelFetch( boneTexture, ivec2( x + 3, y ), 0 );
		return mat4( v1, v2, v3, v4 );
	}
#endif`,Jg=`#ifdef USE_SKINNING
	vec4 skinVertex = bindMatrix * vec4( transformed, 1.0 );
	vec4 skinned = vec4( 0.0 );
	skinned += boneMatX * skinVertex * skinWeight.x;
	skinned += boneMatY * skinVertex * skinWeight.y;
	skinned += boneMatZ * skinVertex * skinWeight.z;
	skinned += boneMatW * skinVertex * skinWeight.w;
	transformed = ( bindMatrixInverse * skinned ).xyz;
#endif`,Kg=`#ifdef USE_SKINNING
	mat4 skinMatrix = mat4( 0.0 );
	skinMatrix += skinWeight.x * boneMatX;
	skinMatrix += skinWeight.y * boneMatY;
	skinMatrix += skinWeight.z * boneMatZ;
	skinMatrix += skinWeight.w * boneMatW;
	skinMatrix = bindMatrixInverse * skinMatrix * bindMatrix;
	objectNormal = vec4( skinMatrix * vec4( objectNormal, 0.0 ) ).xyz;
	#ifdef USE_TANGENT
		objectTangent = vec4( skinMatrix * vec4( objectTangent, 0.0 ) ).xyz;
	#endif
#endif`,Qg=`float specularStrength;
#ifdef USE_SPECULARMAP
	vec4 texelSpecular = texture2D( specularMap, vSpecularMapUv );
	specularStrength = texelSpecular.r;
#else
	specularStrength = 1.0;
#endif`,jg=`#ifdef USE_SPECULARMAP
	uniform sampler2D specularMap;
#endif`,ex=`#if defined( TONE_MAPPING )
	gl_FragColor.rgb = toneMapping( gl_FragColor.rgb );
#endif`,tx=`#ifndef saturate
#define saturate( a ) clamp( a, 0.0, 1.0 )
#endif
uniform float toneMappingExposure;
vec3 LinearToneMapping( vec3 color ) {
	return saturate( toneMappingExposure * color );
}
vec3 ReinhardToneMapping( vec3 color ) {
	color *= toneMappingExposure;
	return saturate( color / ( vec3( 1.0 ) + color ) );
}
vec3 CineonToneMapping( vec3 color ) {
	color *= toneMappingExposure;
	color = max( vec3( 0.0 ), color - 0.004 );
	return pow( ( color * ( 6.2 * color + 0.5 ) ) / ( color * ( 6.2 * color + 1.7 ) + 0.06 ), vec3( 2.2 ) );
}
vec3 RRTAndODTFit( vec3 v ) {
	vec3 a = v * ( v + 0.0245786 ) - 0.000090537;
	vec3 b = v * ( 0.983729 * v + 0.4329510 ) + 0.238081;
	return a / b;
}
vec3 ACESFilmicToneMapping( vec3 color ) {
	const mat3 ACESInputMat = mat3(
		vec3( 0.59719, 0.07600, 0.02840 ),		vec3( 0.35458, 0.90834, 0.13383 ),
		vec3( 0.04823, 0.01566, 0.83777 )
	);
	const mat3 ACESOutputMat = mat3(
		vec3(  1.60475, -0.10208, -0.00327 ),		vec3( -0.53108,  1.10813, -0.07276 ),
		vec3( -0.07367, -0.00605,  1.07602 )
	);
	color *= toneMappingExposure / 0.6;
	color = ACESInputMat * color;
	color = RRTAndODTFit( color );
	color = ACESOutputMat * color;
	return saturate( color );
}
const mat3 LINEAR_REC2020_TO_LINEAR_SRGB = mat3(
	vec3( 1.6605, - 0.1246, - 0.0182 ),
	vec3( - 0.5876, 1.1329, - 0.1006 ),
	vec3( - 0.0728, - 0.0083, 1.1187 )
);
const mat3 LINEAR_SRGB_TO_LINEAR_REC2020 = mat3(
	vec3( 0.6274, 0.0691, 0.0164 ),
	vec3( 0.3293, 0.9195, 0.0880 ),
	vec3( 0.0433, 0.0113, 0.8956 )
);
vec3 agxDefaultContrastApprox( vec3 x ) {
	vec3 x2 = x * x;
	vec3 x4 = x2 * x2;
	return + 15.5 * x4 * x2
		- 40.14 * x4 * x
		+ 31.96 * x4
		- 6.868 * x2 * x
		+ 0.4298 * x2
		+ 0.1191 * x
		- 0.00232;
}
vec3 AgXToneMapping( vec3 color ) {
	const mat3 AgXInsetMatrix = mat3(
		vec3( 0.856627153315983, 0.137318972929847, 0.11189821299995 ),
		vec3( 0.0951212405381588, 0.761241990602591, 0.0767994186031903 ),
		vec3( 0.0482516061458583, 0.101439036467562, 0.811302368396859 )
	);
	const mat3 AgXOutsetMatrix = mat3(
		vec3( 1.1271005818144368, - 0.1413297634984383, - 0.14132976349843826 ),
		vec3( - 0.11060664309660323, 1.157823702216272, - 0.11060664309660294 ),
		vec3( - 0.016493938717834573, - 0.016493938717834257, 1.2519364065950405 )
	);
	const float AgxMinEv = - 12.47393;	const float AgxMaxEv = 4.026069;
	color *= toneMappingExposure;
	color = LINEAR_SRGB_TO_LINEAR_REC2020 * color;
	color = AgXInsetMatrix * color;
	color = max( color, 1e-10 );	color = log2( color );
	color = ( color - AgxMinEv ) / ( AgxMaxEv - AgxMinEv );
	color = clamp( color, 0.0, 1.0 );
	color = agxDefaultContrastApprox( color );
	color = AgXOutsetMatrix * color;
	color = pow( max( vec3( 0.0 ), color ), vec3( 2.2 ) );
	color = LINEAR_REC2020_TO_LINEAR_SRGB * color;
	color = clamp( color, 0.0, 1.0 );
	return color;
}
vec3 NeutralToneMapping( vec3 color ) {
	const float StartCompression = 0.8 - 0.04;
	const float Desaturation = 0.15;
	color *= toneMappingExposure;
	float x = min( color.r, min( color.g, color.b ) );
	float offset = x < 0.08 ? x - 6.25 * x * x : 0.04;
	color -= offset;
	float peak = max( color.r, max( color.g, color.b ) );
	if ( peak < StartCompression ) return color;
	float d = 1. - StartCompression;
	float newPeak = 1. - d * d / ( peak + d - StartCompression );
	color *= newPeak / peak;
	float g = 1. - 1. / ( Desaturation * ( peak - newPeak ) + 1. );
	return mix( color, vec3( newPeak ), g );
}
vec3 CustomToneMapping( vec3 color ) { return color; }`,nx=`#ifdef USE_TRANSMISSION
	material.transmission = transmission;
	material.transmissionAlpha = 1.0;
	material.thickness = thickness;
	material.attenuationDistance = attenuationDistance;
	material.attenuationColor = attenuationColor;
	#ifdef USE_TRANSMISSIONMAP
		material.transmission *= texture2D( transmissionMap, vTransmissionMapUv ).r;
	#endif
	#ifdef USE_THICKNESSMAP
		material.thickness *= texture2D( thicknessMap, vThicknessMapUv ).g;
	#endif
	vec3 pos = vWorldPosition;
	vec3 v = normalize( cameraPosition - pos );
	vec3 n = inverseTransformDirection( normal, viewMatrix );
	vec4 transmitted = getIBLVolumeRefraction(
		n, v, material.roughness, material.diffuseColor, material.specularColor, material.specularF90,
		pos, modelMatrix, viewMatrix, projectionMatrix, material.dispersion, material.ior, material.thickness,
		material.attenuationColor, material.attenuationDistance );
	material.transmissionAlpha = mix( material.transmissionAlpha, transmitted.a, material.transmission );
	totalDiffuse = mix( totalDiffuse, transmitted.rgb, material.transmission );
#endif`,ix=`#ifdef USE_TRANSMISSION
	uniform float transmission;
	uniform float thickness;
	uniform float attenuationDistance;
	uniform vec3 attenuationColor;
	#ifdef USE_TRANSMISSIONMAP
		uniform sampler2D transmissionMap;
	#endif
	#ifdef USE_THICKNESSMAP
		uniform sampler2D thicknessMap;
	#endif
	uniform vec2 transmissionSamplerSize;
	uniform sampler2D transmissionSamplerMap;
	uniform mat4 modelMatrix;
	uniform mat4 projectionMatrix;
	varying vec3 vWorldPosition;
	float w0( float a ) {
		return ( 1.0 / 6.0 ) * ( a * ( a * ( - a + 3.0 ) - 3.0 ) + 1.0 );
	}
	float w1( float a ) {
		return ( 1.0 / 6.0 ) * ( a *  a * ( 3.0 * a - 6.0 ) + 4.0 );
	}
	float w2( float a ){
		return ( 1.0 / 6.0 ) * ( a * ( a * ( - 3.0 * a + 3.0 ) + 3.0 ) + 1.0 );
	}
	float w3( float a ) {
		return ( 1.0 / 6.0 ) * ( a * a * a );
	}
	float g0( float a ) {
		return w0( a ) + w1( a );
	}
	float g1( float a ) {
		return w2( a ) + w3( a );
	}
	float h0( float a ) {
		return - 1.0 + w1( a ) / ( w0( a ) + w1( a ) );
	}
	float h1( float a ) {
		return 1.0 + w3( a ) / ( w2( a ) + w3( a ) );
	}
	vec4 bicubic( sampler2D tex, vec2 uv, vec4 texelSize, float lod ) {
		uv = uv * texelSize.zw + 0.5;
		vec2 iuv = floor( uv );
		vec2 fuv = fract( uv );
		float g0x = g0( fuv.x );
		float g1x = g1( fuv.x );
		float h0x = h0( fuv.x );
		float h1x = h1( fuv.x );
		float h0y = h0( fuv.y );
		float h1y = h1( fuv.y );
		vec2 p0 = ( vec2( iuv.x + h0x, iuv.y + h0y ) - 0.5 ) * texelSize.xy;
		vec2 p1 = ( vec2( iuv.x + h1x, iuv.y + h0y ) - 0.5 ) * texelSize.xy;
		vec2 p2 = ( vec2( iuv.x + h0x, iuv.y + h1y ) - 0.5 ) * texelSize.xy;
		vec2 p3 = ( vec2( iuv.x + h1x, iuv.y + h1y ) - 0.5 ) * texelSize.xy;
		return g0( fuv.y ) * ( g0x * textureLod( tex, p0, lod ) + g1x * textureLod( tex, p1, lod ) ) +
			g1( fuv.y ) * ( g0x * textureLod( tex, p2, lod ) + g1x * textureLod( tex, p3, lod ) );
	}
	vec4 textureBicubic( sampler2D sampler, vec2 uv, float lod ) {
		vec2 fLodSize = vec2( textureSize( sampler, int( lod ) ) );
		vec2 cLodSize = vec2( textureSize( sampler, int( lod + 1.0 ) ) );
		vec2 fLodSizeInv = 1.0 / fLodSize;
		vec2 cLodSizeInv = 1.0 / cLodSize;
		vec4 fSample = bicubic( sampler, uv, vec4( fLodSizeInv, fLodSize ), floor( lod ) );
		vec4 cSample = bicubic( sampler, uv, vec4( cLodSizeInv, cLodSize ), ceil( lod ) );
		return mix( fSample, cSample, fract( lod ) );
	}
	vec3 getVolumeTransmissionRay( const in vec3 n, const in vec3 v, const in float thickness, const in float ior, const in mat4 modelMatrix ) {
		vec3 refractionVector = refract( - v, normalize( n ), 1.0 / ior );
		vec3 modelScale;
		modelScale.x = length( vec3( modelMatrix[ 0 ].xyz ) );
		modelScale.y = length( vec3( modelMatrix[ 1 ].xyz ) );
		modelScale.z = length( vec3( modelMatrix[ 2 ].xyz ) );
		return normalize( refractionVector ) * thickness * modelScale;
	}
	float applyIorToRoughness( const in float roughness, const in float ior ) {
		return roughness * clamp( ior * 2.0 - 2.0, 0.0, 1.0 );
	}
	vec4 getTransmissionSample( const in vec2 fragCoord, const in float roughness, const in float ior ) {
		float lod = log2( transmissionSamplerSize.x ) * applyIorToRoughness( roughness, ior );
		return textureBicubic( transmissionSamplerMap, fragCoord.xy, lod );
	}
	vec3 volumeAttenuation( const in float transmissionDistance, const in vec3 attenuationColor, const in float attenuationDistance ) {
		if ( isinf( attenuationDistance ) ) {
			return vec3( 1.0 );
		} else {
			vec3 attenuationCoefficient = -log( attenuationColor ) / attenuationDistance;
			vec3 transmittance = exp( - attenuationCoefficient * transmissionDistance );			return transmittance;
		}
	}
	vec4 getIBLVolumeRefraction( const in vec3 n, const in vec3 v, const in float roughness, const in vec3 diffuseColor,
		const in vec3 specularColor, const in float specularF90, const in vec3 position, const in mat4 modelMatrix,
		const in mat4 viewMatrix, const in mat4 projMatrix, const in float dispersion, const in float ior, const in float thickness,
		const in vec3 attenuationColor, const in float attenuationDistance ) {
		vec4 transmittedLight;
		vec3 transmittance;
		#ifdef USE_DISPERSION
			float halfSpread = ( ior - 1.0 ) * 0.025 * dispersion;
			vec3 iors = vec3( ior - halfSpread, ior, ior + halfSpread );
			for ( int i = 0; i < 3; i ++ ) {
				vec3 transmissionRay = getVolumeTransmissionRay( n, v, thickness, iors[ i ], modelMatrix );
				vec3 refractedRayExit = position + transmissionRay;
				vec4 ndcPos = projMatrix * viewMatrix * vec4( refractedRayExit, 1.0 );
				vec2 refractionCoords = ndcPos.xy / ndcPos.w;
				refractionCoords += 1.0;
				refractionCoords /= 2.0;
				vec4 transmissionSample = getTransmissionSample( refractionCoords, roughness, iors[ i ] );
				transmittedLight[ i ] = transmissionSample[ i ];
				transmittedLight.a += transmissionSample.a;
				transmittance[ i ] = diffuseColor[ i ] * volumeAttenuation( length( transmissionRay ), attenuationColor, attenuationDistance )[ i ];
			}
			transmittedLight.a /= 3.0;
		#else
			vec3 transmissionRay = getVolumeTransmissionRay( n, v, thickness, ior, modelMatrix );
			vec3 refractedRayExit = position + transmissionRay;
			vec4 ndcPos = projMatrix * viewMatrix * vec4( refractedRayExit, 1.0 );
			vec2 refractionCoords = ndcPos.xy / ndcPos.w;
			refractionCoords += 1.0;
			refractionCoords /= 2.0;
			transmittedLight = getTransmissionSample( refractionCoords, roughness, ior );
			transmittance = diffuseColor * volumeAttenuation( length( transmissionRay ), attenuationColor, attenuationDistance );
		#endif
		vec3 attenuatedColor = transmittance * transmittedLight.rgb;
		vec3 F = EnvironmentBRDF( n, v, specularColor, specularF90, roughness );
		float transmittanceFactor = ( transmittance.r + transmittance.g + transmittance.b ) / 3.0;
		return vec4( ( 1.0 - F ) * attenuatedColor, 1.0 - ( 1.0 - transmittedLight.a ) * transmittanceFactor );
	}
#endif`,rx=`#if defined( USE_UV ) || defined( USE_ANISOTROPY )
	varying vec2 vUv;
#endif
#ifdef USE_MAP
	varying vec2 vMapUv;
#endif
#ifdef USE_ALPHAMAP
	varying vec2 vAlphaMapUv;
#endif
#ifdef USE_LIGHTMAP
	varying vec2 vLightMapUv;
#endif
#ifdef USE_AOMAP
	varying vec2 vAoMapUv;
#endif
#ifdef USE_BUMPMAP
	varying vec2 vBumpMapUv;
#endif
#ifdef USE_NORMALMAP
	varying vec2 vNormalMapUv;
#endif
#ifdef USE_EMISSIVEMAP
	varying vec2 vEmissiveMapUv;
#endif
#ifdef USE_METALNESSMAP
	varying vec2 vMetalnessMapUv;
#endif
#ifdef USE_ROUGHNESSMAP
	varying vec2 vRoughnessMapUv;
#endif
#ifdef USE_ANISOTROPYMAP
	varying vec2 vAnisotropyMapUv;
#endif
#ifdef USE_CLEARCOATMAP
	varying vec2 vClearcoatMapUv;
#endif
#ifdef USE_CLEARCOAT_NORMALMAP
	varying vec2 vClearcoatNormalMapUv;
#endif
#ifdef USE_CLEARCOAT_ROUGHNESSMAP
	varying vec2 vClearcoatRoughnessMapUv;
#endif
#ifdef USE_IRIDESCENCEMAP
	varying vec2 vIridescenceMapUv;
#endif
#ifdef USE_IRIDESCENCE_THICKNESSMAP
	varying vec2 vIridescenceThicknessMapUv;
#endif
#ifdef USE_SHEEN_COLORMAP
	varying vec2 vSheenColorMapUv;
#endif
#ifdef USE_SHEEN_ROUGHNESSMAP
	varying vec2 vSheenRoughnessMapUv;
#endif
#ifdef USE_SPECULARMAP
	varying vec2 vSpecularMapUv;
#endif
#ifdef USE_SPECULAR_COLORMAP
	varying vec2 vSpecularColorMapUv;
#endif
#ifdef USE_SPECULAR_INTENSITYMAP
	varying vec2 vSpecularIntensityMapUv;
#endif
#ifdef USE_TRANSMISSIONMAP
	uniform mat3 transmissionMapTransform;
	varying vec2 vTransmissionMapUv;
#endif
#ifdef USE_THICKNESSMAP
	uniform mat3 thicknessMapTransform;
	varying vec2 vThicknessMapUv;
#endif`,sx=`#if defined( USE_UV ) || defined( USE_ANISOTROPY )
	varying vec2 vUv;
#endif
#ifdef USE_MAP
	uniform mat3 mapTransform;
	varying vec2 vMapUv;
#endif
#ifdef USE_ALPHAMAP
	uniform mat3 alphaMapTransform;
	varying vec2 vAlphaMapUv;
#endif
#ifdef USE_LIGHTMAP
	uniform mat3 lightMapTransform;
	varying vec2 vLightMapUv;
#endif
#ifdef USE_AOMAP
	uniform mat3 aoMapTransform;
	varying vec2 vAoMapUv;
#endif
#ifdef USE_BUMPMAP
	uniform mat3 bumpMapTransform;
	varying vec2 vBumpMapUv;
#endif
#ifdef USE_NORMALMAP
	uniform mat3 normalMapTransform;
	varying vec2 vNormalMapUv;
#endif
#ifdef USE_DISPLACEMENTMAP
	uniform mat3 displacementMapTransform;
	varying vec2 vDisplacementMapUv;
#endif
#ifdef USE_EMISSIVEMAP
	uniform mat3 emissiveMapTransform;
	varying vec2 vEmissiveMapUv;
#endif
#ifdef USE_METALNESSMAP
	uniform mat3 metalnessMapTransform;
	varying vec2 vMetalnessMapUv;
#endif
#ifdef USE_ROUGHNESSMAP
	uniform mat3 roughnessMapTransform;
	varying vec2 vRoughnessMapUv;
#endif
#ifdef USE_ANISOTROPYMAP
	uniform mat3 anisotropyMapTransform;
	varying vec2 vAnisotropyMapUv;
#endif
#ifdef USE_CLEARCOATMAP
	uniform mat3 clearcoatMapTransform;
	varying vec2 vClearcoatMapUv;
#endif
#ifdef USE_CLEARCOAT_NORMALMAP
	uniform mat3 clearcoatNormalMapTransform;
	varying vec2 vClearcoatNormalMapUv;
#endif
#ifdef USE_CLEARCOAT_ROUGHNESSMAP
	uniform mat3 clearcoatRoughnessMapTransform;
	varying vec2 vClearcoatRoughnessMapUv;
#endif
#ifdef USE_SHEEN_COLORMAP
	uniform mat3 sheenColorMapTransform;
	varying vec2 vSheenColorMapUv;
#endif
#ifdef USE_SHEEN_ROUGHNESSMAP
	uniform mat3 sheenRoughnessMapTransform;
	varying vec2 vSheenRoughnessMapUv;
#endif
#ifdef USE_IRIDESCENCEMAP
	uniform mat3 iridescenceMapTransform;
	varying vec2 vIridescenceMapUv;
#endif
#ifdef USE_IRIDESCENCE_THICKNESSMAP
	uniform mat3 iridescenceThicknessMapTransform;
	varying vec2 vIridescenceThicknessMapUv;
#endif
#ifdef USE_SPECULARMAP
	uniform mat3 specularMapTransform;
	varying vec2 vSpecularMapUv;
#endif
#ifdef USE_SPECULAR_COLORMAP
	uniform mat3 specularColorMapTransform;
	varying vec2 vSpecularColorMapUv;
#endif
#ifdef USE_SPECULAR_INTENSITYMAP
	uniform mat3 specularIntensityMapTransform;
	varying vec2 vSpecularIntensityMapUv;
#endif
#ifdef USE_TRANSMISSIONMAP
	uniform mat3 transmissionMapTransform;
	varying vec2 vTransmissionMapUv;
#endif
#ifdef USE_THICKNESSMAP
	uniform mat3 thicknessMapTransform;
	varying vec2 vThicknessMapUv;
#endif`,ax=`#if defined( USE_UV ) || defined( USE_ANISOTROPY )
	vUv = vec3( uv, 1 ).xy;
#endif
#ifdef USE_MAP
	vMapUv = ( mapTransform * vec3( MAP_UV, 1 ) ).xy;
#endif
#ifdef USE_ALPHAMAP
	vAlphaMapUv = ( alphaMapTransform * vec3( ALPHAMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_LIGHTMAP
	vLightMapUv = ( lightMapTransform * vec3( LIGHTMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_AOMAP
	vAoMapUv = ( aoMapTransform * vec3( AOMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_BUMPMAP
	vBumpMapUv = ( bumpMapTransform * vec3( BUMPMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_NORMALMAP
	vNormalMapUv = ( normalMapTransform * vec3( NORMALMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_DISPLACEMENTMAP
	vDisplacementMapUv = ( displacementMapTransform * vec3( DISPLACEMENTMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_EMISSIVEMAP
	vEmissiveMapUv = ( emissiveMapTransform * vec3( EMISSIVEMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_METALNESSMAP
	vMetalnessMapUv = ( metalnessMapTransform * vec3( METALNESSMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_ROUGHNESSMAP
	vRoughnessMapUv = ( roughnessMapTransform * vec3( ROUGHNESSMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_ANISOTROPYMAP
	vAnisotropyMapUv = ( anisotropyMapTransform * vec3( ANISOTROPYMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_CLEARCOATMAP
	vClearcoatMapUv = ( clearcoatMapTransform * vec3( CLEARCOATMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_CLEARCOAT_NORMALMAP
	vClearcoatNormalMapUv = ( clearcoatNormalMapTransform * vec3( CLEARCOAT_NORMALMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_CLEARCOAT_ROUGHNESSMAP
	vClearcoatRoughnessMapUv = ( clearcoatRoughnessMapTransform * vec3( CLEARCOAT_ROUGHNESSMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_IRIDESCENCEMAP
	vIridescenceMapUv = ( iridescenceMapTransform * vec3( IRIDESCENCEMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_IRIDESCENCE_THICKNESSMAP
	vIridescenceThicknessMapUv = ( iridescenceThicknessMapTransform * vec3( IRIDESCENCE_THICKNESSMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_SHEEN_COLORMAP
	vSheenColorMapUv = ( sheenColorMapTransform * vec3( SHEEN_COLORMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_SHEEN_ROUGHNESSMAP
	vSheenRoughnessMapUv = ( sheenRoughnessMapTransform * vec3( SHEEN_ROUGHNESSMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_SPECULARMAP
	vSpecularMapUv = ( specularMapTransform * vec3( SPECULARMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_SPECULAR_COLORMAP
	vSpecularColorMapUv = ( specularColorMapTransform * vec3( SPECULAR_COLORMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_SPECULAR_INTENSITYMAP
	vSpecularIntensityMapUv = ( specularIntensityMapTransform * vec3( SPECULAR_INTENSITYMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_TRANSMISSIONMAP
	vTransmissionMapUv = ( transmissionMapTransform * vec3( TRANSMISSIONMAP_UV, 1 ) ).xy;
#endif
#ifdef USE_THICKNESSMAP
	vThicknessMapUv = ( thicknessMapTransform * vec3( THICKNESSMAP_UV, 1 ) ).xy;
#endif`,ox=`#if defined( USE_ENVMAP ) || defined( DISTANCE ) || defined ( USE_SHADOWMAP ) || defined ( USE_TRANSMISSION ) || NUM_SPOT_LIGHT_COORDS > 0
	vec4 worldPosition = vec4( transformed, 1.0 );
	#ifdef USE_BATCHING
		worldPosition = batchingMatrix * worldPosition;
	#endif
	#ifdef USE_INSTANCING
		worldPosition = instanceMatrix * worldPosition;
	#endif
	worldPosition = modelMatrix * worldPosition;
#endif`,cx=`varying vec2 vUv;
uniform mat3 uvTransform;
void main() {
	vUv = ( uvTransform * vec3( uv, 1 ) ).xy;
	gl_Position = vec4( position.xy, 1.0, 1.0 );
}`,lx=`uniform sampler2D t2D;
uniform float backgroundIntensity;
varying vec2 vUv;
void main() {
	vec4 texColor = texture2D( t2D, vUv );
	#ifdef DECODE_VIDEO_TEXTURE
		texColor = vec4( mix( pow( texColor.rgb * 0.9478672986 + vec3( 0.0521327014 ), vec3( 2.4 ) ), texColor.rgb * 0.0773993808, vec3( lessThanEqual( texColor.rgb, vec3( 0.04045 ) ) ) ), texColor.w );
	#endif
	texColor.rgb *= backgroundIntensity;
	gl_FragColor = texColor;
	#include <tonemapping_fragment>
	#include <colorspace_fragment>
}`,ux=`varying vec3 vWorldDirection;
#include <common>
void main() {
	vWorldDirection = transformDirection( position, modelMatrix );
	#include <begin_vertex>
	#include <project_vertex>
	gl_Position.z = gl_Position.w;
}`,hx=`#ifdef ENVMAP_TYPE_CUBE
	uniform samplerCube envMap;
#elif defined( ENVMAP_TYPE_CUBE_UV )
	uniform sampler2D envMap;
#endif
uniform float flipEnvMap;
uniform float backgroundBlurriness;
uniform float backgroundIntensity;
uniform mat3 backgroundRotation;
varying vec3 vWorldDirection;
#include <cube_uv_reflection_fragment>
void main() {
	#ifdef ENVMAP_TYPE_CUBE
		vec4 texColor = textureCube( envMap, backgroundRotation * vec3( flipEnvMap * vWorldDirection.x, vWorldDirection.yz ) );
	#elif defined( ENVMAP_TYPE_CUBE_UV )
		vec4 texColor = textureCubeUV( envMap, backgroundRotation * vWorldDirection, backgroundBlurriness );
	#else
		vec4 texColor = vec4( 0.0, 0.0, 0.0, 1.0 );
	#endif
	texColor.rgb *= backgroundIntensity;
	gl_FragColor = texColor;
	#include <tonemapping_fragment>
	#include <colorspace_fragment>
}`,fx=`varying vec3 vWorldDirection;
#include <common>
void main() {
	vWorldDirection = transformDirection( position, modelMatrix );
	#include <begin_vertex>
	#include <project_vertex>
	gl_Position.z = gl_Position.w;
}`,dx=`uniform samplerCube tCube;
uniform float tFlip;
uniform float opacity;
varying vec3 vWorldDirection;
void main() {
	vec4 texColor = textureCube( tCube, vec3( tFlip * vWorldDirection.x, vWorldDirection.yz ) );
	gl_FragColor = texColor;
	gl_FragColor.a *= opacity;
	#include <tonemapping_fragment>
	#include <colorspace_fragment>
}`,px=`#include <common>
#include <batching_pars_vertex>
#include <uv_pars_vertex>
#include <displacementmap_pars_vertex>
#include <morphtarget_pars_vertex>
#include <skinning_pars_vertex>
#include <logdepthbuf_pars_vertex>
#include <clipping_planes_pars_vertex>
varying vec2 vHighPrecisionZW;
void main() {
	#include <uv_vertex>
	#include <batching_vertex>
	#include <skinbase_vertex>
	#include <morphinstance_vertex>
	#ifdef USE_DISPLACEMENTMAP
		#include <beginnormal_vertex>
		#include <morphnormal_vertex>
		#include <skinnormal_vertex>
	#endif
	#include <begin_vertex>
	#include <morphtarget_vertex>
	#include <skinning_vertex>
	#include <displacementmap_vertex>
	#include <project_vertex>
	#include <logdepthbuf_vertex>
	#include <clipping_planes_vertex>
	vHighPrecisionZW = gl_Position.zw;
}`,mx=`#if DEPTH_PACKING == 3200
	uniform float opacity;
#endif
#include <common>
#include <packing>
#include <uv_pars_fragment>
#include <map_pars_fragment>
#include <alphamap_pars_fragment>
#include <alphatest_pars_fragment>
#include <alphahash_pars_fragment>
#include <logdepthbuf_pars_fragment>
#include <clipping_planes_pars_fragment>
varying vec2 vHighPrecisionZW;
void main() {
	vec4 diffuseColor = vec4( 1.0 );
	#include <clipping_planes_fragment>
	#if DEPTH_PACKING == 3200
		diffuseColor.a = opacity;
	#endif
	#include <map_fragment>
	#include <alphamap_fragment>
	#include <alphatest_fragment>
	#include <alphahash_fragment>
	#include <logdepthbuf_fragment>
	#ifdef USE_REVERSED_DEPTH_BUFFER
		float fragCoordZ = vHighPrecisionZW[ 0 ] / vHighPrecisionZW[ 1 ];
	#else
		float fragCoordZ = 0.5 * vHighPrecisionZW[ 0 ] / vHighPrecisionZW[ 1 ] + 0.5;
	#endif
	#if DEPTH_PACKING == 3200
		gl_FragColor = vec4( vec3( 1.0 - fragCoordZ ), opacity );
	#elif DEPTH_PACKING == 3201
		gl_FragColor = packDepthToRGBA( fragCoordZ );
	#elif DEPTH_PACKING == 3202
		gl_FragColor = vec4( packDepthToRGB( fragCoordZ ), 1.0 );
	#elif DEPTH_PACKING == 3203
		gl_FragColor = vec4( packDepthToRG( fragCoordZ ), 0.0, 1.0 );
	#endif
}`,gx=`#define DISTANCE
varying vec3 vWorldPosition;
#include <common>
#include <batching_pars_vertex>
#include <uv_pars_vertex>
#include <displacementmap_pars_vertex>
#include <morphtarget_pars_vertex>
#include <skinning_pars_vertex>
#include <clipping_planes_pars_vertex>
void main() {
	#include <uv_vertex>
	#include <batching_vertex>
	#include <skinbase_vertex>
	#include <morphinstance_vertex>
	#ifdef USE_DISPLACEMENTMAP
		#include <beginnormal_vertex>
		#include <morphnormal_vertex>
		#include <skinnormal_vertex>
	#endif
	#include <begin_vertex>
	#include <morphtarget_vertex>
	#include <skinning_vertex>
	#include <displacementmap_vertex>
	#include <project_vertex>
	#include <worldpos_vertex>
	#include <clipping_planes_vertex>
	vWorldPosition = worldPosition.xyz;
}`,xx=`#define DISTANCE
uniform vec3 referencePosition;
uniform float nearDistance;
uniform float farDistance;
varying vec3 vWorldPosition;
#include <common>
#include <packing>
#include <uv_pars_fragment>
#include <map_pars_fragment>
#include <alphamap_pars_fragment>
#include <alphatest_pars_fragment>
#include <alphahash_pars_fragment>
#include <clipping_planes_pars_fragment>
void main () {
	vec4 diffuseColor = vec4( 1.0 );
	#include <clipping_planes_fragment>
	#include <map_fragment>
	#include <alphamap_fragment>
	#include <alphatest_fragment>
	#include <alphahash_fragment>
	float dist = length( vWorldPosition - referencePosition );
	dist = ( dist - nearDistance ) / ( farDistance - nearDistance );
	dist = saturate( dist );
	gl_FragColor = packDepthToRGBA( dist );
}`,vx=`varying vec3 vWorldDirection;
#include <common>
void main() {
	vWorldDirection = transformDirection( position, modelMatrix );
	#include <begin_vertex>
	#include <project_vertex>
}`,_x=`uniform sampler2D tEquirect;
varying vec3 vWorldDirection;
#include <common>
void main() {
	vec3 direction = normalize( vWorldDirection );
	vec2 sampleUV = equirectUv( direction );
	gl_FragColor = texture2D( tEquirect, sampleUV );
	#include <tonemapping_fragment>
	#include <colorspace_fragment>
}`,yx=`uniform float scale;
attribute float lineDistance;
varying float vLineDistance;
#include <common>
#include <uv_pars_vertex>
#include <color_pars_vertex>
#include <fog_pars_vertex>
#include <morphtarget_pars_vertex>
#include <logdepthbuf_pars_vertex>
#include <clipping_planes_pars_vertex>
void main() {
	vLineDistance = scale * lineDistance;
	#include <uv_vertex>
	#include <color_vertex>
	#include <morphinstance_vertex>
	#include <morphcolor_vertex>
	#include <begin_vertex>
	#include <morphtarget_vertex>
	#include <project_vertex>
	#include <logdepthbuf_vertex>
	#include <clipping_planes_vertex>
	#include <fog_vertex>
}`,bx=`uniform vec3 diffuse;
uniform float opacity;
uniform float dashSize;
uniform float totalSize;
varying float vLineDistance;
#include <common>
#include <color_pars_fragment>
#include <uv_pars_fragment>
#include <map_pars_fragment>
#include <fog_pars_fragment>
#include <logdepthbuf_pars_fragment>
#include <clipping_planes_pars_fragment>
void main() {
	vec4 diffuseColor = vec4( diffuse, opacity );
	#include <clipping_planes_fragment>
	if ( mod( vLineDistance, totalSize ) > dashSize ) {
		discard;
	}
	vec3 outgoingLight = vec3( 0.0 );
	#include <logdepthbuf_fragment>
	#include <map_fragment>
	#include <color_fragment>
	outgoingLight = diffuseColor.rgb;
	#include <opaque_fragment>
	#include <tonemapping_fragment>
	#include <colorspace_fragment>
	#include <fog_fragment>
	#include <premultiplied_alpha_fragment>
}`,Sx=`#include <common>
#include <batching_pars_vertex>
#include <uv_pars_vertex>
#include <envmap_pars_vertex>
#include <color_pars_vertex>
#include <fog_pars_vertex>
#include <morphtarget_pars_vertex>
#include <skinning_pars_vertex>
#include <logdepthbuf_pars_vertex>
#include <clipping_planes_pars_vertex>
void main() {
	#include <uv_vertex>
	#include <color_vertex>
	#include <morphinstance_vertex>
	#include <morphcolor_vertex>
	#include <batching_vertex>
	#if defined ( USE_ENVMAP ) || defined ( USE_SKINNING )
		#include <beginnormal_vertex>
		#include <morphnormal_vertex>
		#include <skinbase_vertex>
		#include <skinnormal_vertex>
		#include <defaultnormal_vertex>
	#endif
	#include <begin_vertex>
	#include <morphtarget_vertex>
	#include <skinning_vertex>
	#include <project_vertex>
	#include <logdepthbuf_vertex>
	#include <clipping_planes_vertex>
	#include <worldpos_vertex>
	#include <envmap_vertex>
	#include <fog_vertex>
}`,Mx=`uniform vec3 diffuse;
uniform float opacity;
#ifndef FLAT_SHADED
	varying vec3 vNormal;
#endif
#include <common>
#include <dithering_pars_fragment>
#include <color_pars_fragment>
#include <uv_pars_fragment>
#include <map_pars_fragment>
#include <alphamap_pars_fragment>
#include <alphatest_pars_fragment>
#include <alphahash_pars_fragment>
#include <aomap_pars_fragment>
#include <lightmap_pars_fragment>
#include <envmap_common_pars_fragment>
#include <envmap_pars_fragment>
#include <fog_pars_fragment>
#include <specularmap_pars_fragment>
#include <logdepthbuf_pars_fragment>
#include <clipping_planes_pars_fragment>
void main() {
	vec4 diffuseColor = vec4( diffuse, opacity );
	#include <clipping_planes_fragment>
	#include <logdepthbuf_fragment>
	#include <map_fragment>
	#include <color_fragment>
	#include <alphamap_fragment>
	#include <alphatest_fragment>
	#include <alphahash_fragment>
	#include <specularmap_fragment>
	ReflectedLight reflectedLight = ReflectedLight( vec3( 0.0 ), vec3( 0.0 ), vec3( 0.0 ), vec3( 0.0 ) );
	#ifdef USE_LIGHTMAP
		vec4 lightMapTexel = texture2D( lightMap, vLightMapUv );
		reflectedLight.indirectDiffuse += lightMapTexel.rgb * lightMapIntensity * RECIPROCAL_PI;
	#else
		reflectedLight.indirectDiffuse += vec3( 1.0 );
	#endif
	#include <aomap_fragment>
	reflectedLight.indirectDiffuse *= diffuseColor.rgb;
	vec3 outgoingLight = reflectedLight.indirectDiffuse;
	#include <envmap_fragment>
	#include <opaque_fragment>
	#include <tonemapping_fragment>
	#include <colorspace_fragment>
	#include <fog_fragment>
	#include <premultiplied_alpha_fragment>
	#include <dithering_fragment>
}`,Tx=`#define LAMBERT
varying vec3 vViewPosition;
#include <common>
#include <batching_pars_vertex>
#include <uv_pars_vertex>
#include <displacementmap_pars_vertex>
#include <envmap_pars_vertex>
#include <color_pars_vertex>
#include <fog_pars_vertex>
#include <normal_pars_vertex>
#include <morphtarget_pars_vertex>
#include <skinning_pars_vertex>
#include <shadowmap_pars_vertex>
#include <logdepthbuf_pars_vertex>
#include <clipping_planes_pars_vertex>
void main() {
	#include <uv_vertex>
	#include <color_vertex>
	#include <morphinstance_vertex>
	#include <morphcolor_vertex>
	#include <batching_vertex>
	#include <beginnormal_vertex>
	#include <morphnormal_vertex>
	#include <skinbase_vertex>
	#include <skinnormal_vertex>
	#include <defaultnormal_vertex>
	#include <normal_vertex>
	#include <begin_vertex>
	#include <morphtarget_vertex>
	#include <skinning_vertex>
	#include <displacementmap_vertex>
	#include <project_vertex>
	#include <logdepthbuf_vertex>
	#include <clipping_planes_vertex>
	vViewPosition = - mvPosition.xyz;
	#include <worldpos_vertex>
	#include <envmap_vertex>
	#include <shadowmap_vertex>
	#include <fog_vertex>
}`,wx=`#define LAMBERT
uniform vec3 diffuse;
uniform vec3 emissive;
uniform float opacity;
#include <common>
#include <packing>
#include <dithering_pars_fragment>
#include <color_pars_fragment>
#include <uv_pars_fragment>
#include <map_pars_fragment>
#include <alphamap_pars_fragment>
#include <alphatest_pars_fragment>
#include <alphahash_pars_fragment>
#include <aomap_pars_fragment>
#include <lightmap_pars_fragment>
#include <emissivemap_pars_fragment>
#include <envmap_common_pars_fragment>
#include <envmap_pars_fragment>
#include <fog_pars_fragment>
#include <bsdfs>
#include <lights_pars_begin>
#include <normal_pars_fragment>
#include <lights_lambert_pars_fragment>
#include <shadowmap_pars_fragment>
#include <bumpmap_pars_fragment>
#include <normalmap_pars_fragment>
#include <specularmap_pars_fragment>
#include <logdepthbuf_pars_fragment>
#include <clipping_planes_pars_fragment>
void main() {
	vec4 diffuseColor = vec4( diffuse, opacity );
	#include <clipping_planes_fragment>
	ReflectedLight reflectedLight = ReflectedLight( vec3( 0.0 ), vec3( 0.0 ), vec3( 0.0 ), vec3( 0.0 ) );
	vec3 totalEmissiveRadiance = emissive;
	#include <logdepthbuf_fragment>
	#include <map_fragment>
	#include <color_fragment>
	#include <alphamap_fragment>
	#include <alphatest_fragment>
	#include <alphahash_fragment>
	#include <specularmap_fragment>
	#include <normal_fragment_begin>
	#include <normal_fragment_maps>
	#include <emissivemap_fragment>
	#include <lights_lambert_fragment>
	#include <lights_fragment_begin>
	#include <lights_fragment_maps>
	#include <lights_fragment_end>
	#include <aomap_fragment>
	vec3 outgoingLight = reflectedLight.directDiffuse + reflectedLight.indirectDiffuse + totalEmissiveRadiance;
	#include <envmap_fragment>
	#include <opaque_fragment>
	#include <tonemapping_fragment>
	#include <colorspace_fragment>
	#include <fog_fragment>
	#include <premultiplied_alpha_fragment>
	#include <dithering_fragment>
}`,Ax=`#define MATCAP
varying vec3 vViewPosition;
#include <common>
#include <batching_pars_vertex>
#include <uv_pars_vertex>
#include <color_pars_vertex>
#include <displacementmap_pars_vertex>
#include <fog_pars_vertex>
#include <normal_pars_vertex>
#include <morphtarget_pars_vertex>
#include <skinning_pars_vertex>
#include <logdepthbuf_pars_vertex>
#include <clipping_planes_pars_vertex>
void main() {
	#include <uv_vertex>
	#include <color_vertex>
	#include <morphinstance_vertex>
	#include <morphcolor_vertex>
	#include <batching_vertex>
	#include <beginnormal_vertex>
	#include <morphnormal_vertex>
	#include <skinbase_vertex>
	#include <skinnormal_vertex>
	#include <defaultnormal_vertex>
	#include <normal_vertex>
	#include <begin_vertex>
	#include <morphtarget_vertex>
	#include <skinning_vertex>
	#include <displacementmap_vertex>
	#include <project_vertex>
	#include <logdepthbuf_vertex>
	#include <clipping_planes_vertex>
	#include <fog_vertex>
	vViewPosition = - mvPosition.xyz;
}`,Ex=`#define MATCAP
uniform vec3 diffuse;
uniform float opacity;
uniform sampler2D matcap;
varying vec3 vViewPosition;
#include <common>
#include <dithering_pars_fragment>
#include <color_pars_fragment>
#include <uv_pars_fragment>
#include <map_pars_fragment>
#include <alphamap_pars_fragment>
#include <alphatest_pars_fragment>
#include <alphahash_pars_fragment>
#include <fog_pars_fragment>
#include <normal_pars_fragment>
#include <bumpmap_pars_fragment>
#include <normalmap_pars_fragment>
#include <logdepthbuf_pars_fragment>
#include <clipping_planes_pars_fragment>
void main() {
	vec4 diffuseColor = vec4( diffuse, opacity );
	#include <clipping_planes_fragment>
	#include <logdepthbuf_fragment>
	#include <map_fragment>
	#include <color_fragment>
	#include <alphamap_fragment>
	#include <alphatest_fragment>
	#include <alphahash_fragment>
	#include <normal_fragment_begin>
	#include <normal_fragment_maps>
	vec3 viewDir = normalize( vViewPosition );
	vec3 x = normalize( vec3( viewDir.z, 0.0, - viewDir.x ) );
	vec3 y = cross( viewDir, x );
	vec2 uv = vec2( dot( x, normal ), dot( y, normal ) ) * 0.495 + 0.5;
	#ifdef USE_MATCAP
		vec4 matcapColor = texture2D( matcap, uv );
	#else
		vec4 matcapColor = vec4( vec3( mix( 0.2, 0.8, uv.y ) ), 1.0 );
	#endif
	vec3 outgoingLight = diffuseColor.rgb * matcapColor.rgb;
	#include <opaque_fragment>
	#include <tonemapping_fragment>
	#include <colorspace_fragment>
	#include <fog_fragment>
	#include <premultiplied_alpha_fragment>
	#include <dithering_fragment>
}`,Cx=`#define NORMAL
#if defined( FLAT_SHADED ) || defined( USE_BUMPMAP ) || defined( USE_NORMALMAP_TANGENTSPACE )
	varying vec3 vViewPosition;
#endif
#include <common>
#include <batching_pars_vertex>
#include <uv_pars_vertex>
#include <displacementmap_pars_vertex>
#include <normal_pars_vertex>
#include <morphtarget_pars_vertex>
#include <skinning_pars_vertex>
#include <logdepthbuf_pars_vertex>
#include <clipping_planes_pars_vertex>
void main() {
	#include <uv_vertex>
	#include <batching_vertex>
	#include <beginnormal_vertex>
	#include <morphinstance_vertex>
	#include <morphnormal_vertex>
	#include <skinbase_vertex>
	#include <skinnormal_vertex>
	#include <defaultnormal_vertex>
	#include <normal_vertex>
	#include <begin_vertex>
	#include <morphtarget_vertex>
	#include <skinning_vertex>
	#include <displacementmap_vertex>
	#include <project_vertex>
	#include <logdepthbuf_vertex>
	#include <clipping_planes_vertex>
#if defined( FLAT_SHADED ) || defined( USE_BUMPMAP ) || defined( USE_NORMALMAP_TANGENTSPACE )
	vViewPosition = - mvPosition.xyz;
#endif
}`,Rx=`#define NORMAL
uniform float opacity;
#if defined( FLAT_SHADED ) || defined( USE_BUMPMAP ) || defined( USE_NORMALMAP_TANGENTSPACE )
	varying vec3 vViewPosition;
#endif
#include <packing>
#include <uv_pars_fragment>
#include <normal_pars_fragment>
#include <bumpmap_pars_fragment>
#include <normalmap_pars_fragment>
#include <logdepthbuf_pars_fragment>
#include <clipping_planes_pars_fragment>
void main() {
	vec4 diffuseColor = vec4( 0.0, 0.0, 0.0, opacity );
	#include <clipping_planes_fragment>
	#include <logdepthbuf_fragment>
	#include <normal_fragment_begin>
	#include <normal_fragment_maps>
	gl_FragColor = vec4( packNormalToRGB( normal ), diffuseColor.a );
	#ifdef OPAQUE
		gl_FragColor.a = 1.0;
	#endif
}`,Ix=`#define PHONG
varying vec3 vViewPosition;
#include <common>
#include <batching_pars_vertex>
#include <uv_pars_vertex>
#include <displacementmap_pars_vertex>
#include <envmap_pars_vertex>
#include <color_pars_vertex>
#include <fog_pars_vertex>
#include <normal_pars_vertex>
#include <morphtarget_pars_vertex>
#include <skinning_pars_vertex>
#include <shadowmap_pars_vertex>
#include <logdepthbuf_pars_vertex>
#include <clipping_planes_pars_vertex>
void main() {
	#include <uv_vertex>
	#include <color_vertex>
	#include <morphcolor_vertex>
	#include <batching_vertex>
	#include <beginnormal_vertex>
	#include <morphinstance_vertex>
	#include <morphnormal_vertex>
	#include <skinbase_vertex>
	#include <skinnormal_vertex>
	#include <defaultnormal_vertex>
	#include <normal_vertex>
	#include <begin_vertex>
	#include <morphtarget_vertex>
	#include <skinning_vertex>
	#include <displacementmap_vertex>
	#include <project_vertex>
	#include <logdepthbuf_vertex>
	#include <clipping_planes_vertex>
	vViewPosition = - mvPosition.xyz;
	#include <worldpos_vertex>
	#include <envmap_vertex>
	#include <shadowmap_vertex>
	#include <fog_vertex>
}`,Px=`#define PHONG
uniform vec3 diffuse;
uniform vec3 emissive;
uniform vec3 specular;
uniform float shininess;
uniform float opacity;
#include <common>
#include <packing>
#include <dithering_pars_fragment>
#include <color_pars_fragment>
#include <uv_pars_fragment>
#include <map_pars_fragment>
#include <alphamap_pars_fragment>
#include <alphatest_pars_fragment>
#include <alphahash_pars_fragment>
#include <aomap_pars_fragment>
#include <lightmap_pars_fragment>
#include <emissivemap_pars_fragment>
#include <envmap_common_pars_fragment>
#include <envmap_pars_fragment>
#include <fog_pars_fragment>
#include <bsdfs>
#include <lights_pars_begin>
#include <normal_pars_fragment>
#include <lights_phong_pars_fragment>
#include <shadowmap_pars_fragment>
#include <bumpmap_pars_fragment>
#include <normalmap_pars_fragment>
#include <specularmap_pars_fragment>
#include <logdepthbuf_pars_fragment>
#include <clipping_planes_pars_fragment>
void main() {
	vec4 diffuseColor = vec4( diffuse, opacity );
	#include <clipping_planes_fragment>
	ReflectedLight reflectedLight = ReflectedLight( vec3( 0.0 ), vec3( 0.0 ), vec3( 0.0 ), vec3( 0.0 ) );
	vec3 totalEmissiveRadiance = emissive;
	#include <logdepthbuf_fragment>
	#include <map_fragment>
	#include <color_fragment>
	#include <alphamap_fragment>
	#include <alphatest_fragment>
	#include <alphahash_fragment>
	#include <specularmap_fragment>
	#include <normal_fragment_begin>
	#include <normal_fragment_maps>
	#include <emissivemap_fragment>
	#include <lights_phong_fragment>
	#include <lights_fragment_begin>
	#include <lights_fragment_maps>
	#include <lights_fragment_end>
	#include <aomap_fragment>
	vec3 outgoingLight = reflectedLight.directDiffuse + reflectedLight.indirectDiffuse + reflectedLight.directSpecular + reflectedLight.indirectSpecular + totalEmissiveRadiance;
	#include <envmap_fragment>
	#include <opaque_fragment>
	#include <tonemapping_fragment>
	#include <colorspace_fragment>
	#include <fog_fragment>
	#include <premultiplied_alpha_fragment>
	#include <dithering_fragment>
}`,Dx=`#define STANDARD
varying vec3 vViewPosition;
#ifdef USE_TRANSMISSION
	varying vec3 vWorldPosition;
#endif
#include <common>
#include <batching_pars_vertex>
#include <uv_pars_vertex>
#include <displacementmap_pars_vertex>
#include <color_pars_vertex>
#include <fog_pars_vertex>
#include <normal_pars_vertex>
#include <morphtarget_pars_vertex>
#include <skinning_pars_vertex>
#include <shadowmap_pars_vertex>
#include <logdepthbuf_pars_vertex>
#include <clipping_planes_pars_vertex>
void main() {
	#include <uv_vertex>
	#include <color_vertex>
	#include <morphinstance_vertex>
	#include <morphcolor_vertex>
	#include <batching_vertex>
	#include <beginnormal_vertex>
	#include <morphnormal_vertex>
	#include <skinbase_vertex>
	#include <skinnormal_vertex>
	#include <defaultnormal_vertex>
	#include <normal_vertex>
	#include <begin_vertex>
	#include <morphtarget_vertex>
	#include <skinning_vertex>
	#include <displacementmap_vertex>
	#include <project_vertex>
	#include <logdepthbuf_vertex>
	#include <clipping_planes_vertex>
	vViewPosition = - mvPosition.xyz;
	#include <worldpos_vertex>
	#include <shadowmap_vertex>
	#include <fog_vertex>
#ifdef USE_TRANSMISSION
	vWorldPosition = worldPosition.xyz;
#endif
}`,Fx=`#define STANDARD
#ifdef PHYSICAL
	#define IOR
	#define USE_SPECULAR
#endif
uniform vec3 diffuse;
uniform vec3 emissive;
uniform float roughness;
uniform float metalness;
uniform float opacity;
#ifdef IOR
	uniform float ior;
#endif
#ifdef USE_SPECULAR
	uniform float specularIntensity;
	uniform vec3 specularColor;
	#ifdef USE_SPECULAR_COLORMAP
		uniform sampler2D specularColorMap;
	#endif
	#ifdef USE_SPECULAR_INTENSITYMAP
		uniform sampler2D specularIntensityMap;
	#endif
#endif
#ifdef USE_CLEARCOAT
	uniform float clearcoat;
	uniform float clearcoatRoughness;
#endif
#ifdef USE_DISPERSION
	uniform float dispersion;
#endif
#ifdef USE_IRIDESCENCE
	uniform float iridescence;
	uniform float iridescenceIOR;
	uniform float iridescenceThicknessMinimum;
	uniform float iridescenceThicknessMaximum;
#endif
#ifdef USE_SHEEN
	uniform vec3 sheenColor;
	uniform float sheenRoughness;
	#ifdef USE_SHEEN_COLORMAP
		uniform sampler2D sheenColorMap;
	#endif
	#ifdef USE_SHEEN_ROUGHNESSMAP
		uniform sampler2D sheenRoughnessMap;
	#endif
#endif
#ifdef USE_ANISOTROPY
	uniform vec2 anisotropyVector;
	#ifdef USE_ANISOTROPYMAP
		uniform sampler2D anisotropyMap;
	#endif
#endif
varying vec3 vViewPosition;
#include <common>
#include <packing>
#include <dithering_pars_fragment>
#include <color_pars_fragment>
#include <uv_pars_fragment>
#include <map_pars_fragment>
#include <alphamap_pars_fragment>
#include <alphatest_pars_fragment>
#include <alphahash_pars_fragment>
#include <aomap_pars_fragment>
#include <lightmap_pars_fragment>
#include <emissivemap_pars_fragment>
#include <iridescence_fragment>
#include <cube_uv_reflection_fragment>
#include <envmap_common_pars_fragment>
#include <envmap_physical_pars_fragment>
#include <fog_pars_fragment>
#include <lights_pars_begin>
#include <normal_pars_fragment>
#include <lights_physical_pars_fragment>
#include <transmission_pars_fragment>
#include <shadowmap_pars_fragment>
#include <bumpmap_pars_fragment>
#include <normalmap_pars_fragment>
#include <clearcoat_pars_fragment>
#include <iridescence_pars_fragment>
#include <roughnessmap_pars_fragment>
#include <metalnessmap_pars_fragment>
#include <logdepthbuf_pars_fragment>
#include <clipping_planes_pars_fragment>
void main() {
	vec4 diffuseColor = vec4( diffuse, opacity );
	#include <clipping_planes_fragment>
	ReflectedLight reflectedLight = ReflectedLight( vec3( 0.0 ), vec3( 0.0 ), vec3( 0.0 ), vec3( 0.0 ) );
	vec3 totalEmissiveRadiance = emissive;
	#include <logdepthbuf_fragment>
	#include <map_fragment>
	#include <color_fragment>
	#include <alphamap_fragment>
	#include <alphatest_fragment>
	#include <alphahash_fragment>
	#include <roughnessmap_fragment>
	#include <metalnessmap_fragment>
	#include <normal_fragment_begin>
	#include <normal_fragment_maps>
	#include <clearcoat_normal_fragment_begin>
	#include <clearcoat_normal_fragment_maps>
	#include <emissivemap_fragment>
	#include <lights_physical_fragment>
	#include <lights_fragment_begin>
	#include <lights_fragment_maps>
	#include <lights_fragment_end>
	#include <aomap_fragment>
	vec3 totalDiffuse = reflectedLight.directDiffuse + reflectedLight.indirectDiffuse;
	vec3 totalSpecular = reflectedLight.directSpecular + reflectedLight.indirectSpecular;
	#include <transmission_fragment>
	vec3 outgoingLight = totalDiffuse + totalSpecular + totalEmissiveRadiance;
	#ifdef USE_SHEEN
		float sheenEnergyComp = 1.0 - 0.157 * max3( material.sheenColor );
		outgoingLight = outgoingLight * sheenEnergyComp + sheenSpecularDirect + sheenSpecularIndirect;
	#endif
	#ifdef USE_CLEARCOAT
		float dotNVcc = saturate( dot( geometryClearcoatNormal, geometryViewDir ) );
		vec3 Fcc = F_Schlick( material.clearcoatF0, material.clearcoatF90, dotNVcc );
		outgoingLight = outgoingLight * ( 1.0 - material.clearcoat * Fcc ) + ( clearcoatSpecularDirect + clearcoatSpecularIndirect ) * material.clearcoat;
	#endif
	#include <opaque_fragment>
	#include <tonemapping_fragment>
	#include <colorspace_fragment>
	#include <fog_fragment>
	#include <premultiplied_alpha_fragment>
	#include <dithering_fragment>
}`,Lx=`#define TOON
varying vec3 vViewPosition;
#include <common>
#include <batching_pars_vertex>
#include <uv_pars_vertex>
#include <displacementmap_pars_vertex>
#include <color_pars_vertex>
#include <fog_pars_vertex>
#include <normal_pars_vertex>
#include <morphtarget_pars_vertex>
#include <skinning_pars_vertex>
#include <shadowmap_pars_vertex>
#include <logdepthbuf_pars_vertex>
#include <clipping_planes_pars_vertex>
void main() {
	#include <uv_vertex>
	#include <color_vertex>
	#include <morphinstance_vertex>
	#include <morphcolor_vertex>
	#include <batching_vertex>
	#include <beginnormal_vertex>
	#include <morphnormal_vertex>
	#include <skinbase_vertex>
	#include <skinnormal_vertex>
	#include <defaultnormal_vertex>
	#include <normal_vertex>
	#include <begin_vertex>
	#include <morphtarget_vertex>
	#include <skinning_vertex>
	#include <displacementmap_vertex>
	#include <project_vertex>
	#include <logdepthbuf_vertex>
	#include <clipping_planes_vertex>
	vViewPosition = - mvPosition.xyz;
	#include <worldpos_vertex>
	#include <shadowmap_vertex>
	#include <fog_vertex>
}`,Nx=`#define TOON
uniform vec3 diffuse;
uniform vec3 emissive;
uniform float opacity;
#include <common>
#include <packing>
#include <dithering_pars_fragment>
#include <color_pars_fragment>
#include <uv_pars_fragment>
#include <map_pars_fragment>
#include <alphamap_pars_fragment>
#include <alphatest_pars_fragment>
#include <alphahash_pars_fragment>
#include <aomap_pars_fragment>
#include <lightmap_pars_fragment>
#include <emissivemap_pars_fragment>
#include <gradientmap_pars_fragment>
#include <fog_pars_fragment>
#include <bsdfs>
#include <lights_pars_begin>
#include <normal_pars_fragment>
#include <lights_toon_pars_fragment>
#include <shadowmap_pars_fragment>
#include <bumpmap_pars_fragment>
#include <normalmap_pars_fragment>
#include <logdepthbuf_pars_fragment>
#include <clipping_planes_pars_fragment>
void main() {
	vec4 diffuseColor = vec4( diffuse, opacity );
	#include <clipping_planes_fragment>
	ReflectedLight reflectedLight = ReflectedLight( vec3( 0.0 ), vec3( 0.0 ), vec3( 0.0 ), vec3( 0.0 ) );
	vec3 totalEmissiveRadiance = emissive;
	#include <logdepthbuf_fragment>
	#include <map_fragment>
	#include <color_fragment>
	#include <alphamap_fragment>
	#include <alphatest_fragment>
	#include <alphahash_fragment>
	#include <normal_fragment_begin>
	#include <normal_fragment_maps>
	#include <emissivemap_fragment>
	#include <lights_toon_fragment>
	#include <lights_fragment_begin>
	#include <lights_fragment_maps>
	#include <lights_fragment_end>
	#include <aomap_fragment>
	vec3 outgoingLight = reflectedLight.directDiffuse + reflectedLight.indirectDiffuse + totalEmissiveRadiance;
	#include <opaque_fragment>
	#include <tonemapping_fragment>
	#include <colorspace_fragment>
	#include <fog_fragment>
	#include <premultiplied_alpha_fragment>
	#include <dithering_fragment>
}`,Ux=`uniform float size;
uniform float scale;
#include <common>
#include <color_pars_vertex>
#include <fog_pars_vertex>
#include <morphtarget_pars_vertex>
#include <logdepthbuf_pars_vertex>
#include <clipping_planes_pars_vertex>
#ifdef USE_POINTS_UV
	varying vec2 vUv;
	uniform mat3 uvTransform;
#endif
void main() {
	#ifdef USE_POINTS_UV
		vUv = ( uvTransform * vec3( uv, 1 ) ).xy;
	#endif
	#include <color_vertex>
	#include <morphinstance_vertex>
	#include <morphcolor_vertex>
	#include <begin_vertex>
	#include <morphtarget_vertex>
	#include <project_vertex>
	gl_PointSize = size;
	#ifdef USE_SIZEATTENUATION
		bool isPerspective = isPerspectiveMatrix( projectionMatrix );
		if ( isPerspective ) gl_PointSize *= ( scale / - mvPosition.z );
	#endif
	#include <logdepthbuf_vertex>
	#include <clipping_planes_vertex>
	#include <worldpos_vertex>
	#include <fog_vertex>
}`,Bx=`uniform vec3 diffuse;
uniform float opacity;
#include <common>
#include <color_pars_fragment>
#include <map_particle_pars_fragment>
#include <alphatest_pars_fragment>
#include <alphahash_pars_fragment>
#include <fog_pars_fragment>
#include <logdepthbuf_pars_fragment>
#include <clipping_planes_pars_fragment>
void main() {
	vec4 diffuseColor = vec4( diffuse, opacity );
	#include <clipping_planes_fragment>
	vec3 outgoingLight = vec3( 0.0 );
	#include <logdepthbuf_fragment>
	#include <map_particle_fragment>
	#include <color_fragment>
	#include <alphatest_fragment>
	#include <alphahash_fragment>
	outgoingLight = diffuseColor.rgb;
	#include <opaque_fragment>
	#include <tonemapping_fragment>
	#include <colorspace_fragment>
	#include <fog_fragment>
	#include <premultiplied_alpha_fragment>
}`,Ox=`#include <common>
#include <batching_pars_vertex>
#include <fog_pars_vertex>
#include <morphtarget_pars_vertex>
#include <skinning_pars_vertex>
#include <logdepthbuf_pars_vertex>
#include <shadowmap_pars_vertex>
void main() {
	#include <batching_vertex>
	#include <beginnormal_vertex>
	#include <morphinstance_vertex>
	#include <morphnormal_vertex>
	#include <skinbase_vertex>
	#include <skinnormal_vertex>
	#include <defaultnormal_vertex>
	#include <begin_vertex>
	#include <morphtarget_vertex>
	#include <skinning_vertex>
	#include <project_vertex>
	#include <logdepthbuf_vertex>
	#include <worldpos_vertex>
	#include <shadowmap_vertex>
	#include <fog_vertex>
}`,zx=`uniform vec3 color;
uniform float opacity;
#include <common>
#include <packing>
#include <fog_pars_fragment>
#include <bsdfs>
#include <lights_pars_begin>
#include <logdepthbuf_pars_fragment>
#include <shadowmap_pars_fragment>
#include <shadowmask_pars_fragment>
void main() {
	#include <logdepthbuf_fragment>
	gl_FragColor = vec4( color, opacity * ( 1.0 - getShadowMask() ) );
	#include <tonemapping_fragment>
	#include <colorspace_fragment>
	#include <fog_fragment>
}`,kx=`uniform float rotation;
uniform vec2 center;
#include <common>
#include <uv_pars_vertex>
#include <fog_pars_vertex>
#include <logdepthbuf_pars_vertex>
#include <clipping_planes_pars_vertex>
void main() {
	#include <uv_vertex>
	vec4 mvPosition = modelViewMatrix[ 3 ];
	vec2 scale = vec2( length( modelMatrix[ 0 ].xyz ), length( modelMatrix[ 1 ].xyz ) );
	#ifndef USE_SIZEATTENUATION
		bool isPerspective = isPerspectiveMatrix( projectionMatrix );
		if ( isPerspective ) scale *= - mvPosition.z;
	#endif
	vec2 alignedPosition = ( position.xy - ( center - vec2( 0.5 ) ) ) * scale;
	vec2 rotatedPosition;
	rotatedPosition.x = cos( rotation ) * alignedPosition.x - sin( rotation ) * alignedPosition.y;
	rotatedPosition.y = sin( rotation ) * alignedPosition.x + cos( rotation ) * alignedPosition.y;
	mvPosition.xy += rotatedPosition;
	gl_Position = projectionMatrix * mvPosition;
	#include <logdepthbuf_vertex>
	#include <clipping_planes_vertex>
	#include <fog_vertex>
}`,Vx=`uniform vec3 diffuse;
uniform float opacity;
#include <common>
#include <uv_pars_fragment>
#include <map_pars_fragment>
#include <alphamap_pars_fragment>
#include <alphatest_pars_fragment>
#include <alphahash_pars_fragment>
#include <fog_pars_fragment>
#include <logdepthbuf_pars_fragment>
#include <clipping_planes_pars_fragment>
void main() {
	vec4 diffuseColor = vec4( diffuse, opacity );
	#include <clipping_planes_fragment>
	vec3 outgoingLight = vec3( 0.0 );
	#include <logdepthbuf_fragment>
	#include <map_fragment>
	#include <alphamap_fragment>
	#include <alphatest_fragment>
	#include <alphahash_fragment>
	outgoingLight = diffuseColor.rgb;
	#include <opaque_fragment>
	#include <tonemapping_fragment>
	#include <colorspace_fragment>
	#include <fog_fragment>
}`,rt={alphahash_fragment:l0,alphahash_pars_fragment:u0,alphamap_fragment:h0,alphamap_pars_fragment:f0,alphatest_fragment:d0,alphatest_pars_fragment:p0,aomap_fragment:m0,aomap_pars_fragment:g0,batching_pars_vertex:x0,batching_vertex:v0,begin_vertex:_0,beginnormal_vertex:y0,bsdfs:b0,iridescence_fragment:S0,bumpmap_pars_fragment:M0,clipping_planes_fragment:T0,clipping_planes_pars_fragment:w0,clipping_planes_pars_vertex:A0,clipping_planes_vertex:E0,color_fragment:C0,color_pars_fragment:R0,color_pars_vertex:I0,color_vertex:P0,common:D0,cube_uv_reflection_fragment:F0,defaultnormal_vertex:L0,displacementmap_pars_vertex:N0,displacementmap_vertex:U0,emissivemap_fragment:B0,emissivemap_pars_fragment:O0,colorspace_fragment:z0,colorspace_pars_fragment:k0,envmap_fragment:V0,envmap_common_pars_fragment:H0,envmap_pars_fragment:G0,envmap_pars_vertex:W0,envmap_physical_pars_fragment:tg,envmap_vertex:X0,fog_vertex:q0,fog_pars_vertex:Y0,fog_fragment:Z0,fog_pars_fragment:$0,gradientmap_pars_fragment:J0,lightmap_pars_fragment:K0,lights_lambert_fragment:Q0,lights_lambert_pars_fragment:j0,lights_pars_begin:eg,lights_toon_fragment:ng,lights_toon_pars_fragment:ig,lights_phong_fragment:rg,lights_phong_pars_fragment:sg,lights_physical_fragment:ag,lights_physical_pars_fragment:og,lights_fragment_begin:cg,lights_fragment_maps:lg,lights_fragment_end:ug,logdepthbuf_fragment:hg,logdepthbuf_pars_fragment:fg,logdepthbuf_pars_vertex:dg,logdepthbuf_vertex:pg,map_fragment:mg,map_pars_fragment:gg,map_particle_fragment:xg,map_particle_pars_fragment:vg,metalnessmap_fragment:_g,metalnessmap_pars_fragment:yg,morphinstance_vertex:bg,morphcolor_vertex:Sg,morphnormal_vertex:Mg,morphtarget_pars_vertex:Tg,morphtarget_vertex:wg,normal_fragment_begin:Ag,normal_fragment_maps:Eg,normal_pars_fragment:Cg,normal_pars_vertex:Rg,normal_vertex:Ig,normalmap_pars_fragment:Pg,clearcoat_normal_fragment_begin:Dg,clearcoat_normal_fragment_maps:Fg,clearcoat_pars_fragment:Lg,iridescence_pars_fragment:Ng,opaque_fragment:Ug,packing:Bg,premultiplied_alpha_fragment:Og,project_vertex:zg,dithering_fragment:kg,dithering_pars_fragment:Vg,roughnessmap_fragment:Hg,roughnessmap_pars_fragment:Gg,shadowmap_pars_fragment:Wg,shadowmap_pars_vertex:Xg,shadowmap_vertex:qg,shadowmask_pars_fragment:Yg,skinbase_vertex:Zg,skinning_pars_vertex:$g,skinning_vertex:Jg,skinnormal_vertex:Kg,specularmap_fragment:Qg,specularmap_pars_fragment:jg,tonemapping_fragment:ex,tonemapping_pars_fragment:tx,transmission_fragment:nx,transmission_pars_fragment:ix,uv_pars_fragment:rx,uv_pars_vertex:sx,uv_vertex:ax,worldpos_vertex:ox,background_vert:cx,background_frag:lx,backgroundCube_vert:ux,backgroundCube_frag:hx,cube_vert:fx,cube_frag:dx,depth_vert:px,depth_frag:mx,distanceRGBA_vert:gx,distanceRGBA_frag:xx,equirect_vert:vx,equirect_frag:_x,linedashed_vert:yx,linedashed_frag:bx,meshbasic_vert:Sx,meshbasic_frag:Mx,meshlambert_vert:Tx,meshlambert_frag:wx,meshmatcap_vert:Ax,meshmatcap_frag:Ex,meshnormal_vert:Cx,meshnormal_frag:Rx,meshphong_vert:Ix,meshphong_frag:Px,meshphysical_vert:Dx,meshphysical_frag:Fx,meshtoon_vert:Lx,meshtoon_frag:Nx,points_vert:Ux,points_frag:Bx,shadow_vert:Ox,shadow_frag:zx,sprite_vert:kx,sprite_frag:Vx},Se={common:{diffuse:{value:new Ye(16777215)},opacity:{value:1},map:{value:null},mapTransform:{value:new et},alphaMap:{value:null},alphaMapTransform:{value:new et},alphaTest:{value:0}},specularmap:{specularMap:{value:null},specularMapTransform:{value:new et}},envmap:{envMap:{value:null},envMapRotation:{value:new et},flipEnvMap:{value:-1},reflectivity:{value:1},ior:{value:1.5},refractionRatio:{value:.98},dfgLUT:{value:null}},aomap:{aoMap:{value:null},aoMapIntensity:{value:1},aoMapTransform:{value:new et}},lightmap:{lightMap:{value:null},lightMapIntensity:{value:1},lightMapTransform:{value:new et}},bumpmap:{bumpMap:{value:null},bumpMapTransform:{value:new et},bumpScale:{value:1}},normalmap:{normalMap:{value:null},normalMapTransform:{value:new et},normalScale:{value:new Le(1,1)}},displacementmap:{displacementMap:{value:null},displacementMapTransform:{value:new et},displacementScale:{value:1},displacementBias:{value:0}},emissivemap:{emissiveMap:{value:null},emissiveMapTransform:{value:new et}},metalnessmap:{metalnessMap:{value:null},metalnessMapTransform:{value:new et}},roughnessmap:{roughnessMap:{value:null},roughnessMapTransform:{value:new et}},gradientmap:{gradientMap:{value:null}},fog:{fogDensity:{value:25e-5},fogNear:{value:1},fogFar:{value:2e3},fogColor:{value:new Ye(16777215)}},lights:{ambientLightColor:{value:[]},lightProbe:{value:[]},directionalLights:{value:[],properties:{direction:{},color:{}}},directionalLightShadows:{value:[],properties:{shadowIntensity:1,shadowBias:{},shadowNormalBias:{},shadowRadius:{},shadowMapSize:{}}},directionalShadowMap:{value:[]},directionalShadowMatrix:{value:[]},spotLights:{value:[],properties:{color:{},position:{},direction:{},distance:{},coneCos:{},penumbraCos:{},decay:{}}},spotLightShadows:{value:[],properties:{shadowIntensity:1,shadowBias:{},shadowNormalBias:{},shadowRadius:{},shadowMapSize:{}}},spotLightMap:{value:[]},spotShadowMap:{value:[]},spotLightMatrix:{value:[]},pointLights:{value:[],properties:{color:{},position:{},decay:{},distance:{}}},pointLightShadows:{value:[],properties:{shadowIntensity:1,shadowBias:{},shadowNormalBias:{},shadowRadius:{},shadowMapSize:{},shadowCameraNear:{},shadowCameraFar:{}}},pointShadowMap:{value:[]},pointShadowMatrix:{value:[]},hemisphereLights:{value:[],properties:{direction:{},skyColor:{},groundColor:{}}},rectAreaLights:{value:[],properties:{color:{},position:{},width:{},height:{}}},ltc_1:{value:null},ltc_2:{value:null}},points:{diffuse:{value:new Ye(16777215)},opacity:{value:1},size:{value:1},scale:{value:1},map:{value:null},alphaMap:{value:null},alphaMapTransform:{value:new et},alphaTest:{value:0},uvTransform:{value:new et}},sprite:{diffuse:{value:new Ye(16777215)},opacity:{value:1},center:{value:new Le(.5,.5)},rotation:{value:0},map:{value:null},mapTransform:{value:new et},alphaMap:{value:null},alphaMapTransform:{value:new et},alphaTest:{value:0}}},ti={basic:{uniforms:pn([Se.common,Se.specularmap,Se.envmap,Se.aomap,Se.lightmap,Se.fog]),vertexShader:rt.meshbasic_vert,fragmentShader:rt.meshbasic_frag},lambert:{uniforms:pn([Se.common,Se.specularmap,Se.envmap,Se.aomap,Se.lightmap,Se.emissivemap,Se.bumpmap,Se.normalmap,Se.displacementmap,Se.fog,Se.lights,{emissive:{value:new Ye(0)}}]),vertexShader:rt.meshlambert_vert,fragmentShader:rt.meshlambert_frag},phong:{uniforms:pn([Se.common,Se.specularmap,Se.envmap,Se.aomap,Se.lightmap,Se.emissivemap,Se.bumpmap,Se.normalmap,Se.displacementmap,Se.fog,Se.lights,{emissive:{value:new Ye(0)},specular:{value:new Ye(1118481)},shininess:{value:30}}]),vertexShader:rt.meshphong_vert,fragmentShader:rt.meshphong_frag},standard:{uniforms:pn([Se.common,Se.envmap,Se.aomap,Se.lightmap,Se.emissivemap,Se.bumpmap,Se.normalmap,Se.displacementmap,Se.roughnessmap,Se.metalnessmap,Se.fog,Se.lights,{emissive:{value:new Ye(0)},roughness:{value:1},metalness:{value:0},envMapIntensity:{value:1}}]),vertexShader:rt.meshphysical_vert,fragmentShader:rt.meshphysical_frag},toon:{uniforms:pn([Se.common,Se.aomap,Se.lightmap,Se.emissivemap,Se.bumpmap,Se.normalmap,Se.displacementmap,Se.gradientmap,Se.fog,Se.lights,{emissive:{value:new Ye(0)}}]),vertexShader:rt.meshtoon_vert,fragmentShader:rt.meshtoon_frag},matcap:{uniforms:pn([Se.common,Se.bumpmap,Se.normalmap,Se.displacementmap,Se.fog,{matcap:{value:null}}]),vertexShader:rt.meshmatcap_vert,fragmentShader:rt.meshmatcap_frag},points:{uniforms:pn([Se.points,Se.fog]),vertexShader:rt.points_vert,fragmentShader:rt.points_frag},dashed:{uniforms:pn([Se.common,Se.fog,{scale:{value:1},dashSize:{value:1},totalSize:{value:2}}]),vertexShader:rt.linedashed_vert,fragmentShader:rt.linedashed_frag},depth:{uniforms:pn([Se.common,Se.displacementmap]),vertexShader:rt.depth_vert,fragmentShader:rt.depth_frag},normal:{uniforms:pn([Se.common,Se.bumpmap,Se.normalmap,Se.displacementmap,{opacity:{value:1}}]),vertexShader:rt.meshnormal_vert,fragmentShader:rt.meshnormal_frag},sprite:{uniforms:pn([Se.sprite,Se.fog]),vertexShader:rt.sprite_vert,fragmentShader:rt.sprite_frag},background:{uniforms:{uvTransform:{value:new et},t2D:{value:null},backgroundIntensity:{value:1}},vertexShader:rt.background_vert,fragmentShader:rt.background_frag},backgroundCube:{uniforms:{envMap:{value:null},flipEnvMap:{value:-1},backgroundBlurriness:{value:0},backgroundIntensity:{value:1},backgroundRotation:{value:new et}},vertexShader:rt.backgroundCube_vert,fragmentShader:rt.backgroundCube_frag},cube:{uniforms:{tCube:{value:null},tFlip:{value:-1},opacity:{value:1}},vertexShader:rt.cube_vert,fragmentShader:rt.cube_frag},equirect:{uniforms:{tEquirect:{value:null}},vertexShader:rt.equirect_vert,fragmentShader:rt.equirect_frag},distanceRGBA:{uniforms:pn([Se.common,Se.displacementmap,{referencePosition:{value:new k},nearDistance:{value:1},farDistance:{value:1e3}}]),vertexShader:rt.distanceRGBA_vert,fragmentShader:rt.distanceRGBA_frag},shadow:{uniforms:pn([Se.lights,Se.fog,{color:{value:new Ye(0)},opacity:{value:1}}]),vertexShader:rt.shadow_vert,fragmentShader:rt.shadow_frag}};ti.physical={uniforms:pn([ti.standard.uniforms,{clearcoat:{value:0},clearcoatMap:{value:null},clearcoatMapTransform:{value:new et},clearcoatNormalMap:{value:null},clearcoatNormalMapTransform:{value:new et},clearcoatNormalScale:{value:new Le(1,1)},clearcoatRoughness:{value:0},clearcoatRoughnessMap:{value:null},clearcoatRoughnessMapTransform:{value:new et},dispersion:{value:0},iridescence:{value:0},iridescenceMap:{value:null},iridescenceMapTransform:{value:new et},iridescenceIOR:{value:1.3},iridescenceThicknessMinimum:{value:100},iridescenceThicknessMaximum:{value:400},iridescenceThicknessMap:{value:null},iridescenceThicknessMapTransform:{value:new et},sheen:{value:0},sheenColor:{value:new Ye(0)},sheenColorMap:{value:null},sheenColorMapTransform:{value:new et},sheenRoughness:{value:1},sheenRoughnessMap:{value:null},sheenRoughnessMapTransform:{value:new et},transmission:{value:0},transmissionMap:{value:null},transmissionMapTransform:{value:new et},transmissionSamplerSize:{value:new Le},transmissionSamplerMap:{value:null},thickness:{value:0},thicknessMap:{value:null},thicknessMapTransform:{value:new et},attenuationDistance:{value:0},attenuationColor:{value:new Ye(0)},specularColor:{value:new Ye(1,1,1)},specularColorMap:{value:null},specularColorMapTransform:{value:new et},specularIntensity:{value:1},specularIntensityMap:{value:null},specularIntensityMapTransform:{value:new et},anisotropyVector:{value:new Le},anisotropyMap:{value:null},anisotropyMapTransform:{value:new et}}]),vertexShader:rt.meshphysical_vert,fragmentShader:rt.meshphysical_frag};var fc={r:0,b:0,g:0},lr=new Xn,Hx=new Xe;function Gx(i,e,t,n,r,s,a){let o=new Ye(0),c=s===!0?0:1,u,f,h=null,l=0,p=null;function g(y){let M=y.isScene===!0?y.background:null;return M&&M.isTexture&&(M=(y.backgroundBlurriness>0?t:e).get(M)),M}function b(y){let M=!1,w=g(y);w===null?d(o,c):w&&w.isColor&&(d(w,1),M=!0);let A=i.xr.getEnvironmentBlendMode();A==="additive"?n.buffers.color.setClear(0,0,0,1,a):A==="alpha-blend"&&n.buffers.color.setClear(0,0,0,0,a),(i.autoClear||M)&&(n.buffers.depth.setTest(!0),n.buffers.depth.setMask(!0),n.buffers.color.setMask(!0),i.clear(i.autoClearColor,i.autoClearDepth,i.autoClearStencil))}function m(y,M){let w=g(M);w&&(w.isCubeTexture||w.mapping===na)?(f===void 0&&(f=new rn(new qr(1,1,1),new Xt({name:"BackgroundCubeMaterial",uniforms:cr(ti.backgroundCube.uniforms),vertexShader:ti.backgroundCube.vertexShader,fragmentShader:ti.backgroundCube.fragmentShader,side:Zt,depthTest:!1,depthWrite:!1,fog:!1,allowOverride:!1})),f.geometry.deleteAttribute("normal"),f.geometry.deleteAttribute("uv"),f.onBeforeRender=function(A,I,D){this.matrixWorld.copyPosition(D.matrixWorld)},Object.defineProperty(f.material,"envMap",{get:function(){return this.uniforms.envMap.value}}),r.update(f)),lr.copy(M.backgroundRotation),lr.x*=-1,lr.y*=-1,lr.z*=-1,w.isCubeTexture&&w.isRenderTargetTexture===!1&&(lr.y*=-1,lr.z*=-1),f.material.uniforms.envMap.value=w,f.material.uniforms.flipEnvMap.value=w.isCubeTexture&&w.isRenderTargetTexture===!1?-1:1,f.material.uniforms.backgroundBlurriness.value=M.backgroundBlurriness,f.material.uniforms.backgroundIntensity.value=M.backgroundIntensity,f.material.uniforms.backgroundRotation.value.setFromMatrix4(Hx.makeRotationFromEuler(lr)),f.material.toneMapped=dt.getTransfer(w.colorSpace)!==bt,(h!==w||l!==w.version||p!==i.toneMapping)&&(f.material.needsUpdate=!0,h=w,l=w.version,p=i.toneMapping),f.layers.enableAll(),y.unshift(f,f.geometry,f.material,0,0,null)):w&&w.isTexture&&(u===void 0&&(u=new rn(new Xs(2,2),new Xt({name:"BackgroundMaterial",uniforms:cr(ti.background.uniforms),vertexShader:ti.background.vertexShader,fragmentShader:ti.background.fragmentShader,side:Mn,depthTest:!1,depthWrite:!1,fog:!1,allowOverride:!1})),u.geometry.deleteAttribute("normal"),Object.defineProperty(u.material,"map",{get:function(){return this.uniforms.t2D.value}}),r.update(u)),u.material.uniforms.t2D.value=w,u.material.uniforms.backgroundIntensity.value=M.backgroundIntensity,u.material.toneMapped=dt.getTransfer(w.colorSpace)!==bt,w.matrixAutoUpdate===!0&&w.updateMatrix(),u.material.uniforms.uvTransform.value.copy(w.matrix),(h!==w||l!==w.version||p!==i.toneMapping)&&(u.material.needsUpdate=!0,h=w,l=w.version,p=i.toneMapping),u.layers.enableAll(),y.unshift(u,u.geometry,u.material,0,0,null))}function d(y,M){y.getRGB(fc,Du(i)),n.buffers.color.setClear(fc.r,fc.g,fc.b,M,a)}function _(){f!==void 0&&(f.geometry.dispose(),f.material.dispose(),f=void 0),u!==void 0&&(u.geometry.dispose(),u.material.dispose(),u=void 0)}return{getClearColor:function(){return o},setClearColor:function(y,M=1){o.set(y),c=M,d(o,c)},getClearAlpha:function(){return c},setClearAlpha:function(y){c=y,d(o,c)},render:b,addToRenderList:m,dispose:_}}function Wx(i,e){let t=i.getParameter(i.MAX_VERTEX_ATTRIBS),n={},r=l(null),s=r,a=!1;function o(S,P,L,O,H){let q=!1,Y=h(O,L,P);s!==Y&&(s=Y,u(s.object)),q=p(S,O,L,H),q&&g(S,O,L,H),H!==null&&e.update(H,i.ELEMENT_ARRAY_BUFFER),(q||a)&&(a=!1,M(S,P,L,O),H!==null&&i.bindBuffer(i.ELEMENT_ARRAY_BUFFER,e.get(H).buffer))}function c(){return i.createVertexArray()}function u(S){return i.bindVertexArray(S)}function f(S){return i.deleteVertexArray(S)}function h(S,P,L){let O=L.wireframe===!0,H=n[S.id];H===void 0&&(H={},n[S.id]=H);let q=H[P.id];q===void 0&&(q={},H[P.id]=q);let Y=q[O];return Y===void 0&&(Y=l(c()),q[O]=Y),Y}function l(S){let P=[],L=[],O=[];for(let H=0;H<t;H++)P[H]=0,L[H]=0,O[H]=0;return{geometry:null,program:null,wireframe:!1,newAttributes:P,enabledAttributes:L,attributeDivisors:O,object:S,attributes:{},index:null}}function p(S,P,L,O){let H=s.attributes,q=P.attributes,Y=0,he=L.getAttributes();for(let j in he)if(he[j].location>=0){let ce=H[j],we=q[j];if(we===void 0&&(j==="instanceMatrix"&&S.instanceMatrix&&(we=S.instanceMatrix),j==="instanceColor"&&S.instanceColor&&(we=S.instanceColor)),ce===void 0||ce.attribute!==we||we&&ce.data!==we.data)return!0;Y++}return s.attributesNum!==Y||s.index!==O}function g(S,P,L,O){let H={},q=P.attributes,Y=0,he=L.getAttributes();for(let j in he)if(he[j].location>=0){let ce=q[j];ce===void 0&&(j==="instanceMatrix"&&S.instanceMatrix&&(ce=S.instanceMatrix),j==="instanceColor"&&S.instanceColor&&(ce=S.instanceColor));let we={};we.attribute=ce,ce&&ce.data&&(we.data=ce.data),H[j]=we,Y++}s.attributes=H,s.attributesNum=Y,s.index=O}function b(){let S=s.newAttributes;for(let P=0,L=S.length;P<L;P++)S[P]=0}function m(S){d(S,0)}function d(S,P){let L=s.newAttributes,O=s.enabledAttributes,H=s.attributeDivisors;L[S]=1,O[S]===0&&(i.enableVertexAttribArray(S),O[S]=1),H[S]!==P&&(i.vertexAttribDivisor(S,P),H[S]=P)}function _(){let S=s.newAttributes,P=s.enabledAttributes;for(let L=0,O=P.length;L<O;L++)P[L]!==S[L]&&(i.disableVertexAttribArray(L),P[L]=0)}function y(S,P,L,O,H,q,Y){Y===!0?i.vertexAttribIPointer(S,P,L,H,q):i.vertexAttribPointer(S,P,L,O,H,q)}function M(S,P,L,O){b();let H=O.attributes,q=L.getAttributes(),Y=P.defaultAttributeValues;for(let he in q){let j=q[he];if(j.location>=0){let le=H[he];if(le===void 0&&(he==="instanceMatrix"&&S.instanceMatrix&&(le=S.instanceMatrix),he==="instanceColor"&&S.instanceColor&&(le=S.instanceColor)),le!==void 0){let ce=le.normalized,we=le.itemSize,Ce=e.get(le);if(Ce===void 0)continue;let ke=Ce.buffer,ct=Ce.type,nt=Ce.bytesPerElement,K=ct===i.INT||ct===i.UNSIGNED_INT||le.gpuType===Ni;if(le.isInterleavedBufferAttribute){let re=le.data,be=re.stride,We=le.offset;if(re.isInstancedInterleavedBuffer){for(let Pe=0;Pe<j.locationSize;Pe++)d(j.location+Pe,re.meshPerAttribute);S.isInstancedMesh!==!0&&O._maxInstanceCount===void 0&&(O._maxInstanceCount=re.meshPerAttribute*re.count)}else for(let Pe=0;Pe<j.locationSize;Pe++)m(j.location+Pe);i.bindBuffer(i.ARRAY_BUFFER,ke);for(let Pe=0;Pe<j.locationSize;Pe++)y(j.location+Pe,we/j.locationSize,ct,ce,be*nt,(We+we/j.locationSize*Pe)*nt,K)}else{if(le.isInstancedBufferAttribute){for(let re=0;re<j.locationSize;re++)d(j.location+re,le.meshPerAttribute);S.isInstancedMesh!==!0&&O._maxInstanceCount===void 0&&(O._maxInstanceCount=le.meshPerAttribute*le.count)}else for(let re=0;re<j.locationSize;re++)m(j.location+re);i.bindBuffer(i.ARRAY_BUFFER,ke);for(let re=0;re<j.locationSize;re++)y(j.location+re,we/j.locationSize,ct,ce,we*nt,we/j.locationSize*re*nt,K)}}else if(Y!==void 0){let ce=Y[he];if(ce!==void 0)switch(ce.length){case 2:i.vertexAttrib2fv(j.location,ce);break;case 3:i.vertexAttrib3fv(j.location,ce);break;case 4:i.vertexAttrib4fv(j.location,ce);break;default:i.vertexAttrib1fv(j.location,ce)}}}}_()}function w(){D();for(let S in n){let P=n[S];for(let L in P){let O=P[L];for(let H in O)f(O[H].object),delete O[H];delete P[L]}delete n[S]}}function A(S){if(n[S.id]===void 0)return;let P=n[S.id];for(let L in P){let O=P[L];for(let H in O)f(O[H].object),delete O[H];delete P[L]}delete n[S.id]}function I(S){for(let P in n){let L=n[P];if(L[S.id]===void 0)continue;let O=L[S.id];for(let H in O)f(O[H].object),delete O[H];delete L[S.id]}}function D(){T(),a=!0,s!==r&&(s=r,u(s.object))}function T(){r.geometry=null,r.program=null,r.wireframe=!1}return{setup:o,reset:D,resetDefaultState:T,dispose:w,releaseStatesOfGeometry:A,releaseStatesOfProgram:I,initAttributes:b,enableAttribute:m,disableUnusedAttributes:_}}function Xx(i,e,t){let n;function r(u){n=u}function s(u,f){i.drawArrays(n,u,f),t.update(f,n,1)}function a(u,f,h){h!==0&&(i.drawArraysInstanced(n,u,f,h),t.update(f,n,h))}function o(u,f,h){if(h===0)return;e.get("WEBGL_multi_draw").multiDrawArraysWEBGL(n,u,0,f,0,h);let p=0;for(let g=0;g<h;g++)p+=f[g];t.update(p,n,1)}function c(u,f,h,l){if(h===0)return;let p=e.get("WEBGL_multi_draw");if(p===null)for(let g=0;g<u.length;g++)a(u[g],f[g],l[g]);else{p.multiDrawArraysInstancedWEBGL(n,u,0,f,0,l,0,h);let g=0;for(let b=0;b<h;b++)g+=f[b]*l[b];t.update(g,n,1)}}this.setMode=r,this.render=s,this.renderInstances=a,this.renderMultiDraw=o,this.renderMultiDrawInstances=c}function qx(i,e,t,n){let r;function s(){if(r!==void 0)return r;if(e.has("EXT_texture_filter_anisotropic")===!0){let I=e.get("EXT_texture_filter_anisotropic");r=i.getParameter(I.MAX_TEXTURE_MAX_ANISOTROPY_EXT)}else r=0;return r}function a(I){return!(I!==He&&n.convert(I)!==i.getParameter(i.IMPLEMENTATION_COLOR_READ_FORMAT))}function o(I){let D=I===_t&&(e.has("EXT_color_buffer_half_float")||e.has("EXT_color_buffer_float"));return!(I!==dn&&n.convert(I)!==i.getParameter(i.IMPLEMENTATION_COLOR_READ_TYPE)&&I!==qe&&!D)}function c(I){if(I==="highp"){if(i.getShaderPrecisionFormat(i.VERTEX_SHADER,i.HIGH_FLOAT).precision>0&&i.getShaderPrecisionFormat(i.FRAGMENT_SHADER,i.HIGH_FLOAT).precision>0)return"highp";I="mediump"}return I==="mediump"&&i.getShaderPrecisionFormat(i.VERTEX_SHADER,i.MEDIUM_FLOAT).precision>0&&i.getShaderPrecisionFormat(i.FRAGMENT_SHADER,i.MEDIUM_FLOAT).precision>0?"mediump":"lowp"}let u=t.precision!==void 0?t.precision:"highp",f=c(u);f!==u&&(Ze("WebGLRenderer:",u,"not supported, using",f,"instead."),u=f);let h=t.logarithmicDepthBuffer===!0,l=t.reversedDepthBuffer===!0&&e.has("EXT_clip_control"),p=i.getParameter(i.MAX_TEXTURE_IMAGE_UNITS),g=i.getParameter(i.MAX_VERTEX_TEXTURE_IMAGE_UNITS),b=i.getParameter(i.MAX_TEXTURE_SIZE),m=i.getParameter(i.MAX_CUBE_MAP_TEXTURE_SIZE),d=i.getParameter(i.MAX_VERTEX_ATTRIBS),_=i.getParameter(i.MAX_VERTEX_UNIFORM_VECTORS),y=i.getParameter(i.MAX_VARYING_VECTORS),M=i.getParameter(i.MAX_FRAGMENT_UNIFORM_VECTORS),w=g>0,A=i.getParameter(i.MAX_SAMPLES);return{isWebGL2:!0,getMaxAnisotropy:s,getMaxPrecision:c,textureFormatReadable:a,textureTypeReadable:o,precision:u,logarithmicDepthBuffer:h,reversedDepthBuffer:l,maxTextures:p,maxVertexTextures:g,maxTextureSize:b,maxCubemapSize:m,maxAttributes:d,maxVertexUniforms:_,maxVaryings:y,maxFragmentUniforms:M,vertexTextures:w,maxSamples:A}}function Yx(i){let e=this,t=null,n=0,r=!1,s=!1,a=new Sn,o=new et,c={value:null,needsUpdate:!1};this.uniform=c,this.numPlanes=0,this.numIntersection=0,this.init=function(h,l){let p=h.length!==0||l||n!==0||r;return r=l,n=h.length,p},this.beginShadows=function(){s=!0,f(null)},this.endShadows=function(){s=!1},this.setGlobalState=function(h,l){t=f(h,l,0)},this.setState=function(h,l,p){let g=h.clippingPlanes,b=h.clipIntersection,m=h.clipShadows,d=i.get(h);if(!r||g===null||g.length===0||s&&!m)s?f(null):u();else{let _=s?0:n,y=_*4,M=d.clippingState||null;c.value=M,M=f(g,l,y,p);for(let w=0;w!==y;++w)M[w]=t[w];d.clippingState=M,this.numIntersection=b?this.numPlanes:0,this.numPlanes+=_}};function u(){c.value!==t&&(c.value=t,c.needsUpdate=n>0),e.numPlanes=n,e.numIntersection=0}function f(h,l,p,g){let b=h!==null?h.length:0,m=null;if(b!==0){if(m=c.value,g!==!0||m===null){let d=p+b*4,_=l.matrixWorldInverse;o.getNormalMatrix(_),(m===null||m.length<d)&&(m=new Float32Array(d));for(let y=0,M=p;y!==b;++y,M+=4)a.copy(h[y]).applyMatrix4(_,o),a.normal.toArray(m,M),m[M+3]=a.constant}c.value=m,c.needsUpdate=!0}return e.numPlanes=b,e.numIntersection=0,m}}function Zx(i){let e=new WeakMap;function t(a,o){return o===ei?a.mapping=ar:o===Lo&&(a.mapping=or),a}function n(a){if(a&&a.isTexture){let o=a.mapping;if(o===ei||o===Lo)if(e.has(a)){let c=e.get(a).texture;return t(c,a.mapping)}else{let c=a.image;if(c&&c.height>0){let u=new uo(c.height);return u.fromEquirectangularTexture(i,a),e.set(a,u),a.addEventListener("dispose",r),t(u.texture,a.mapping)}else return null}}return a}function r(a){let o=a.target;o.removeEventListener("dispose",r);let c=e.get(o);c!==void 0&&(e.delete(o),c.dispose())}function s(){e=new WeakMap}return{get:n,dispose:s}}var Oi=4,Jf=[.125,.215,.35,.446,.526,.582],hr=20,$x=256,ua=new pi,Kf=new Ye,Uu=null,Bu=0,Ou=0,zu=!1,Jx=new k,pc=class{constructor(e){this._renderer=e,this._pingPongRenderTarget=null,this._lodMax=0,this._cubeSize=0,this._sizeLods=[],this._sigmas=[],this._lodMeshes=[],this._backgroundBox=null,this._cubemapMaterial=null,this._equirectMaterial=null,this._blurMaterial=null,this._ggxMaterial=null}fromScene(e,t=0,n=.1,r=100,s={}){let{size:a=256,position:o=Jx}=s;Uu=this._renderer.getRenderTarget(),Bu=this._renderer.getActiveCubeFace(),Ou=this._renderer.getActiveMipmapLevel(),zu=this._renderer.xr.enabled,this._renderer.xr.enabled=!1,this._setSize(a);let c=this._allocateTargets();return c.depthBuffer=!0,this._sceneToCubeUV(e,n,r,c,o),t>0&&this._blur(c,0,0,t),this._applyPMREM(c),this._cleanup(c),c}fromEquirectangular(e,t=null){return this._fromTexture(e,t)}fromCubemap(e,t=null){return this._fromTexture(e,t)}compileCubemapShader(){this._cubemapMaterial===null&&(this._cubemapMaterial=ed(),this._compileMaterial(this._cubemapMaterial))}compileEquirectangularShader(){this._equirectMaterial===null&&(this._equirectMaterial=jf(),this._compileMaterial(this._equirectMaterial))}dispose(){this._dispose(),this._cubemapMaterial!==null&&this._cubemapMaterial.dispose(),this._equirectMaterial!==null&&this._equirectMaterial.dispose(),this._backgroundBox!==null&&(this._backgroundBox.geometry.dispose(),this._backgroundBox.material.dispose())}_setSize(e){this._lodMax=Math.floor(Math.log2(e)),this._cubeSize=Math.pow(2,this._lodMax)}_dispose(){this._blurMaterial!==null&&this._blurMaterial.dispose(),this._ggxMaterial!==null&&this._ggxMaterial.dispose(),this._pingPongRenderTarget!==null&&this._pingPongRenderTarget.dispose();for(let e=0;e<this._lodMeshes.length;e++)this._lodMeshes[e].geometry.dispose()}_cleanup(e){this._renderer.setRenderTarget(Uu,Bu,Ou),this._renderer.xr.enabled=zu,e.scissorTest=!1,es(e,0,0,e.width,e.height)}_fromTexture(e,t){e.mapping===ar||e.mapping===or?this._setSize(e.image.length===0?16:e.image[0].width||e.image[0].image.width):this._setSize(e.image.width/4),Uu=this._renderer.getRenderTarget(),Bu=this._renderer.getActiveCubeFace(),Ou=this._renderer.getActiveMipmapLevel(),zu=this._renderer.xr.enabled,this._renderer.xr.enabled=!1;let n=t||this._allocateTargets();return this._textureToCubeUV(e,n),this._applyPMREM(n),this._cleanup(n),n}_allocateTargets(){let e=3*Math.max(this._cubeSize,112),t=4*this._cubeSize,n={magFilter:ft,minFilter:ft,generateMipmaps:!1,type:_t,format:He,colorSpace:Gt,depthBuffer:!1},r=Qf(e,t,n);if(this._pingPongRenderTarget===null||this._pingPongRenderTarget.width!==e||this._pingPongRenderTarget.height!==t){this._pingPongRenderTarget!==null&&this._dispose(),this._pingPongRenderTarget=Qf(e,t,n);let{_lodMax:s}=this;({lodMeshes:this._lodMeshes,sizeLods:this._sizeLods,sigmas:this._sigmas}=Kx(s)),this._blurMaterial=jx(s,e,t)}return r}_compileMaterial(e){let t=new rn(new Bt,e);this._renderer.compile(t,ua)}_sceneToCubeUV(e,t,n,r,s){let c=new kt(90,1,t,n),u=[1,-1,1,1,1,1],f=[1,1,1,-1,-1,-1],h=this._renderer,l=h.autoClear,p=h.toneMapping;h.getClearColor(Kf),h.toneMapping=qn,h.autoClear=!1,h.state.buffers.depth.getReversed()&&(h.setRenderTarget(r),h.clearDepth(),h.setRenderTarget(null)),this._backgroundBox===null&&(this._backgroundBox=new rn(new qr,new tr({name:"PMREM.Background",side:Zt,depthWrite:!1,depthTest:!1})));let b=this._backgroundBox,m=b.material,d=!1,_=e.background;_?_.isColor&&(m.color.copy(_),e.background=null,d=!0):(m.color.copy(Kf),d=!0);for(let y=0;y<6;y++){let M=y%3;M===0?(c.up.set(0,u[y],0),c.position.set(s.x,s.y,s.z),c.lookAt(s.x+f[y],s.y,s.z)):M===1?(c.up.set(0,0,u[y]),c.position.set(s.x,s.y,s.z),c.lookAt(s.x,s.y+f[y],s.z)):(c.up.set(0,u[y],0),c.position.set(s.x,s.y,s.z),c.lookAt(s.x,s.y,s.z+f[y]));let w=this._cubeSize;es(r,M*w,y>2?w:0,w,w),h.setRenderTarget(r),d&&h.render(b,c),h.render(e,c)}h.toneMapping=p,h.autoClear=l,e.background=_}_textureToCubeUV(e,t){let n=this._renderer,r=e.mapping===ar||e.mapping===or;r?(this._cubemapMaterial===null&&(this._cubemapMaterial=ed()),this._cubemapMaterial.uniforms.flipEnvMap.value=e.isRenderTargetTexture===!1?-1:1):this._equirectMaterial===null&&(this._equirectMaterial=jf());let s=r?this._cubemapMaterial:this._equirectMaterial,a=this._lodMeshes[0];a.material=s;let o=s.uniforms;o.envMap.value=e;let c=this._cubeSize;es(t,0,0,3*c,2*c),n.setRenderTarget(t),n.render(a,ua)}_applyPMREM(e){let t=this._renderer,n=t.autoClear;t.autoClear=!1;let r=this._lodMeshes.length;for(let s=1;s<r;s++)this._applyGGXFilter(e,s-1,s);t.autoClear=n}_applyGGXFilter(e,t,n){let r=this._renderer,s=this._pingPongRenderTarget;if(this._ggxMaterial===null){let _=3*Math.max(this._cubeSize,16),y=4*this._cubeSize;this._ggxMaterial=Qx(this._lodMax,_,y)}let a=this._ggxMaterial,o=this._lodMeshes[n];o.material=a;let c=a.uniforms,u=n/(this._lodMeshes.length-1),f=t/(this._lodMeshes.length-1),h=Math.sqrt(u*u-f*f),l=.05+u*.95,p=h*l,{_lodMax:g}=this,b=this._sizeLods[n],m=3*b*(n>g-Oi?n-g+Oi:0),d=4*(this._cubeSize-b);c.envMap.value=e.texture,c.roughness.value=p,c.mipInt.value=g-t,es(s,m,d,3*b,2*b),r.setRenderTarget(s),r.render(o,ua),c.envMap.value=s.texture,c.roughness.value=0,c.mipInt.value=g-n,es(e,m,d,3*b,2*b),r.setRenderTarget(e),r.render(o,ua)}_blur(e,t,n,r,s){let a=this._pingPongRenderTarget;this._halfBlur(e,a,t,n,r,"latitudinal",s),this._halfBlur(a,e,n,n,r,"longitudinal",s)}_halfBlur(e,t,n,r,s,a,o){let c=this._renderer,u=this._blurMaterial;a!=="latitudinal"&&a!=="longitudinal"&&ut("blur direction must be either latitudinal or longitudinal!");let f=3,h=this._lodMeshes[r];h.material=u;let l=u.uniforms,p=this._sizeLods[n]-1,g=isFinite(s)?Math.PI/(2*p):2*Math.PI/(2*hr-1),b=s/g,m=isFinite(s)?1+Math.floor(f*b):hr;m>hr&&Ze(`sigmaRadians, ${s}, is too large and will clip, as it requested ${m} samples when the maximum is set to ${hr}`);let d=[],_=0;for(let I=0;I<hr;++I){let D=I/b,T=Math.exp(-D*D/2);d.push(T),I===0?_+=T:I<m&&(_+=2*T)}for(let I=0;I<d.length;I++)d[I]=d[I]/_;l.envMap.value=e.texture,l.samples.value=m,l.weights.value=d,l.latitudinal.value=a==="latitudinal",o&&(l.poleAxis.value=o);let{_lodMax:y}=this;l.dTheta.value=g,l.mipInt.value=y-n;let M=this._sizeLods[r],w=3*M*(r>y-Oi?r-y+Oi:0),A=4*(this._cubeSize-M);es(t,w,A,3*M,2*M),c.setRenderTarget(t),c.render(h,ua)}};function Kx(i){let e=[],t=[],n=[],r=i,s=i-Oi+1+Jf.length;for(let a=0;a<s;a++){let o=Math.pow(2,r);e.push(o);let c=1/o;a>i-Oi?c=Jf[a-i+Oi-1]:a===0&&(c=0),t.push(c);let u=1/(o-2),f=-u,h=1+u,l=[f,f,h,f,h,h,f,f,h,h,f,h],p=6,g=6,b=3,m=2,d=1,_=new Float32Array(b*g*p),y=new Float32Array(m*g*p),M=new Float32Array(d*g*p);for(let A=0;A<p;A++){let I=A%3*2/3-1,D=A>2?0:-1,T=[I,D,0,I+2/3,D,0,I+2/3,D+1,0,I,D,0,I+2/3,D+1,0,I,D+1,0];_.set(T,b*g*A),y.set(l,m*g*A);let S=[A,A,A,A,A,A];M.set(S,d*g*A)}let w=new Bt;w.setAttribute("position",new mt(_,b)),w.setAttribute("uv",new mt(y,m)),w.setAttribute("faceIndex",new mt(M,d)),n.push(new rn(w,null)),r>Oi&&r--}return{lodMeshes:n,sizeLods:e,sigmas:t}}function Qf(i,e,t){let n=new Yt(i,e,t);return n.texture.mapping=na,n.texture.name="PMREM.cubeUv",n.scissorTest=!0,n}function es(i,e,t,n,r){i.viewport.set(e,t,n,r),i.scissor.set(e,t,n,r)}function Qx(i,e,t){return new Xt({name:"PMREMGGXConvolution",defines:{GGX_SAMPLES:$x,CUBEUV_TEXEL_WIDTH:1/e,CUBEUV_TEXEL_HEIGHT:1/t,CUBEUV_MAX_MIP:`${i}.0`},uniforms:{envMap:{value:null},roughness:{value:0},mipInt:{value:0}},vertexShader:xc(),fragmentShader:`

			precision highp float;
			precision highp int;

			varying vec3 vOutputDirection;

			uniform sampler2D envMap;
			uniform float roughness;
			uniform float mipInt;

			#define ENVMAP_TYPE_CUBE_UV
			#include <cube_uv_reflection_fragment>

			#define PI 3.14159265359

			// Van der Corput radical inverse
			float radicalInverse_VdC(uint bits) {
				bits = (bits << 16u) | (bits >> 16u);
				bits = ((bits & 0x55555555u) << 1u) | ((bits & 0xAAAAAAAAu) >> 1u);
				bits = ((bits & 0x33333333u) << 2u) | ((bits & 0xCCCCCCCCu) >> 2u);
				bits = ((bits & 0x0F0F0F0Fu) << 4u) | ((bits & 0xF0F0F0F0u) >> 4u);
				bits = ((bits & 0x00FF00FFu) << 8u) | ((bits & 0xFF00FF00u) >> 8u);
				return float(bits) * 2.3283064365386963e-10; // / 0x100000000
			}

			// Hammersley sequence
			vec2 hammersley(uint i, uint N) {
				return vec2(float(i) / float(N), radicalInverse_VdC(i));
			}

			// GGX VNDF importance sampling (Eric Heitz 2018)
			// "Sampling the GGX Distribution of Visible Normals"
			// https://jcgt.org/published/0007/04/01/
			vec3 importanceSampleGGX_VNDF(vec2 Xi, vec3 V, float roughness) {
				float alpha = roughness * roughness;

				// Section 3.2: Transform view direction to hemisphere configuration
				vec3 Vh = normalize(vec3(alpha * V.x, alpha * V.y, V.z));

				// Section 4.1: Orthonormal basis
				float lensq = Vh.x * Vh.x + Vh.y * Vh.y;
				vec3 T1 = lensq > 0.0 ? vec3(-Vh.y, Vh.x, 0.0) / sqrt(lensq) : vec3(1.0, 0.0, 0.0);
				vec3 T2 = cross(Vh, T1);

				// Section 4.2: Parameterization of projected area
				float r = sqrt(Xi.x);
				float phi = 2.0 * PI * Xi.y;
				float t1 = r * cos(phi);
				float t2 = r * sin(phi);
				float s = 0.5 * (1.0 + Vh.z);
				t2 = (1.0 - s) * sqrt(1.0 - t1 * t1) + s * t2;

				// Section 4.3: Reprojection onto hemisphere
				vec3 Nh = t1 * T1 + t2 * T2 + sqrt(max(0.0, 1.0 - t1 * t1 - t2 * t2)) * Vh;

				// Section 3.4: Transform back to ellipsoid configuration
				return normalize(vec3(alpha * Nh.x, alpha * Nh.y, max(0.0, Nh.z)));
			}

			void main() {
				vec3 N = normalize(vOutputDirection);
				vec3 V = N; // Assume view direction equals normal for pre-filtering

				vec3 prefilteredColor = vec3(0.0);
				float totalWeight = 0.0;

				// For very low roughness, just sample the environment directly
				if (roughness < 0.001) {
					gl_FragColor = vec4(bilinearCubeUV(envMap, N, mipInt), 1.0);
					return;
				}

				// Tangent space basis for VNDF sampling
				vec3 up = abs(N.z) < 0.999 ? vec3(0.0, 0.0, 1.0) : vec3(1.0, 0.0, 0.0);
				vec3 tangent = normalize(cross(up, N));
				vec3 bitangent = cross(N, tangent);

				for(uint i = 0u; i < uint(GGX_SAMPLES); i++) {
					vec2 Xi = hammersley(i, uint(GGX_SAMPLES));

					// For PMREM, V = N, so in tangent space V is always (0, 0, 1)
					vec3 H_tangent = importanceSampleGGX_VNDF(Xi, vec3(0.0, 0.0, 1.0), roughness);

					// Transform H back to world space
					vec3 H = normalize(tangent * H_tangent.x + bitangent * H_tangent.y + N * H_tangent.z);
					vec3 L = normalize(2.0 * dot(V, H) * H - V);

					float NdotL = max(dot(N, L), 0.0);

					if(NdotL > 0.0) {
						// Sample environment at fixed mip level
						// VNDF importance sampling handles the distribution filtering
						vec3 sampleColor = bilinearCubeUV(envMap, L, mipInt);

						// Weight by NdotL for the split-sum approximation
						// VNDF PDF naturally accounts for the visible microfacet distribution
						prefilteredColor += sampleColor * NdotL;
						totalWeight += NdotL;
					}
				}

				if (totalWeight > 0.0) {
					prefilteredColor = prefilteredColor / totalWeight;
				}

				gl_FragColor = vec4(prefilteredColor, 1.0);
			}
		`,blending:$t,depthTest:!1,depthWrite:!1})}function jx(i,e,t){let n=new Float32Array(hr),r=new k(0,1,0);return new Xt({name:"SphericalGaussianBlur",defines:{n:hr,CUBEUV_TEXEL_WIDTH:1/e,CUBEUV_TEXEL_HEIGHT:1/t,CUBEUV_MAX_MIP:`${i}.0`},uniforms:{envMap:{value:null},samples:{value:1},weights:{value:n},latitudinal:{value:!1},dTheta:{value:0},mipInt:{value:0},poleAxis:{value:r}},vertexShader:xc(),fragmentShader:`

			precision mediump float;
			precision mediump int;

			varying vec3 vOutputDirection;

			uniform sampler2D envMap;
			uniform int samples;
			uniform float weights[ n ];
			uniform bool latitudinal;
			uniform float dTheta;
			uniform float mipInt;
			uniform vec3 poleAxis;

			#define ENVMAP_TYPE_CUBE_UV
			#include <cube_uv_reflection_fragment>

			vec3 getSample( float theta, vec3 axis ) {

				float cosTheta = cos( theta );
				// Rodrigues' axis-angle rotation
				vec3 sampleDirection = vOutputDirection * cosTheta
					+ cross( axis, vOutputDirection ) * sin( theta )
					+ axis * dot( axis, vOutputDirection ) * ( 1.0 - cosTheta );

				return bilinearCubeUV( envMap, sampleDirection, mipInt );

			}

			void main() {

				vec3 axis = latitudinal ? poleAxis : cross( poleAxis, vOutputDirection );

				if ( all( equal( axis, vec3( 0.0 ) ) ) ) {

					axis = vec3( vOutputDirection.z, 0.0, - vOutputDirection.x );

				}

				axis = normalize( axis );

				gl_FragColor = vec4( 0.0, 0.0, 0.0, 1.0 );
				gl_FragColor.rgb += weights[ 0 ] * getSample( 0.0, axis );

				for ( int i = 1; i < n; i++ ) {

					if ( i >= samples ) {

						break;

					}

					float theta = dTheta * float( i );
					gl_FragColor.rgb += weights[ i ] * getSample( -1.0 * theta, axis );
					gl_FragColor.rgb += weights[ i ] * getSample( theta, axis );

				}

			}
		`,blending:$t,depthTest:!1,depthWrite:!1})}function jf(){return new Xt({name:"EquirectangularToCubeUV",uniforms:{envMap:{value:null}},vertexShader:xc(),fragmentShader:`

			precision mediump float;
			precision mediump int;

			varying vec3 vOutputDirection;

			uniform sampler2D envMap;

			#include <common>

			void main() {

				vec3 outputDirection = normalize( vOutputDirection );
				vec2 uv = equirectUv( outputDirection );

				gl_FragColor = vec4( texture2D ( envMap, uv ).rgb, 1.0 );

			}
		`,blending:$t,depthTest:!1,depthWrite:!1})}function ed(){return new Xt({name:"CubemapToCubeUV",uniforms:{envMap:{value:null},flipEnvMap:{value:-1}},vertexShader:xc(),fragmentShader:`

			precision mediump float;
			precision mediump int;

			uniform float flipEnvMap;

			varying vec3 vOutputDirection;

			uniform samplerCube envMap;

			void main() {

				gl_FragColor = textureCube( envMap, vec3( flipEnvMap * vOutputDirection.x, vOutputDirection.yz ) );

			}
		`,blending:$t,depthTest:!1,depthWrite:!1})}function xc(){return`

		precision mediump float;
		precision mediump int;

		attribute float faceIndex;

		varying vec3 vOutputDirection;

		// RH coordinate system; PMREM face-indexing convention
		vec3 getDirection( vec2 uv, float face ) {

			uv = 2.0 * uv - 1.0;

			vec3 direction = vec3( uv, 1.0 );

			if ( face == 0.0 ) {

				direction = direction.zyx; // ( 1, v, u ) pos x

			} else if ( face == 1.0 ) {

				direction = direction.xzy;
				direction.xz *= -1.0; // ( -u, 1, -v ) pos y

			} else if ( face == 2.0 ) {

				direction.x *= -1.0; // ( -u, v, 1 ) pos z

			} else if ( face == 3.0 ) {

				direction = direction.zyx;
				direction.xz *= -1.0; // ( -1, v, -u ) neg x

			} else if ( face == 4.0 ) {

				direction = direction.xzy;
				direction.xy *= -1.0; // ( -u, -1, v ) neg y

			} else if ( face == 5.0 ) {

				direction.z *= -1.0; // ( u, v, -1 ) neg z

			}

			return direction;

		}

		void main() {

			vOutputDirection = getDirection( uv, faceIndex );
			gl_Position = vec4( position, 1.0 );

		}
	`}function ev(i){let e=new WeakMap,t=null;function n(o){if(o&&o.isTexture){let c=o.mapping,u=c===ei||c===Lo,f=c===ar||c===or;if(u||f){let h=e.get(o),l=h!==void 0?h.texture.pmremVersion:0;if(o.isRenderTargetTexture&&o.pmremVersion!==l)return t===null&&(t=new pc(i)),h=u?t.fromEquirectangular(o,h):t.fromCubemap(o,h),h.texture.pmremVersion=o.pmremVersion,e.set(o,h),h.texture;if(h!==void 0)return h.texture;{let p=o.image;return u&&p&&p.height>0||f&&p&&r(p)?(t===null&&(t=new pc(i)),h=u?t.fromEquirectangular(o):t.fromCubemap(o),h.texture.pmremVersion=o.pmremVersion,e.set(o,h),o.addEventListener("dispose",s),h.texture):null}}}return o}function r(o){let c=0,u=6;for(let f=0;f<u;f++)o[f]!==void 0&&c++;return c===u}function s(o){let c=o.target;c.removeEventListener("dispose",s);let u=e.get(c);u!==void 0&&(e.delete(c),u.dispose())}function a(){e=new WeakMap,t!==null&&(t.dispose(),t=null)}return{get:n,dispose:a}}function tv(i){let e={};function t(n){if(e[n]!==void 0)return e[n];let r=i.getExtension(n);return e[n]=r,r}return{has:function(n){return t(n)!==null},init:function(){t("EXT_color_buffer_float"),t("WEBGL_clip_cull_distance"),t("OES_texture_float_linear"),t("EXT_color_buffer_half_float"),t("WEBGL_multisampled_render_to_texture"),t("WEBGL_render_shared_exponent")},get:function(n){let r=t(n);return r===null&&Gr("WebGLRenderer: "+n+" extension not supported."),r}}}function nv(i,e,t,n){let r={},s=new WeakMap;function a(h){let l=h.target;l.index!==null&&e.remove(l.index);for(let g in l.attributes)e.remove(l.attributes[g]);l.removeEventListener("dispose",a),delete r[l.id];let p=s.get(l);p&&(e.remove(p),s.delete(l)),n.releaseStatesOfGeometry(l),l.isInstancedBufferGeometry===!0&&delete l._maxInstanceCount,t.memory.geometries--}function o(h,l){return r[l.id]===!0||(l.addEventListener("dispose",a),r[l.id]=!0,t.memory.geometries++),l}function c(h){let l=h.attributes;for(let p in l)e.update(l[p],i.ARRAY_BUFFER)}function u(h){let l=[],p=h.index,g=h.attributes.position,b=0;if(p!==null){let _=p.array;b=p.version;for(let y=0,M=_.length;y<M;y+=3){let w=_[y+0],A=_[y+1],I=_[y+2];l.push(w,A,A,I,I,w)}}else if(g!==void 0){let _=g.array;b=g.version;for(let y=0,M=_.length/3-1;y<M;y+=3){let w=y+0,A=y+1,I=y+2;l.push(w,A,A,I,I,w)}}else return;let m=new(Iu(l)?nr:ks)(l,1);m.version=b;let d=s.get(h);d&&e.remove(d),s.set(h,m)}function f(h){let l=s.get(h);if(l){let p=h.index;p!==null&&l.version<p.version&&u(h)}else u(h);return s.get(h)}return{get:o,update:c,getWireframeAttribute:f}}function iv(i,e,t){let n;function r(l){n=l}let s,a;function o(l){s=l.type,a=l.bytesPerElement}function c(l,p){i.drawElements(n,p,s,l*a),t.update(p,n,1)}function u(l,p,g){g!==0&&(i.drawElementsInstanced(n,p,s,l*a,g),t.update(p,n,g))}function f(l,p,g){if(g===0)return;e.get("WEBGL_multi_draw").multiDrawElementsWEBGL(n,p,0,s,l,0,g);let m=0;for(let d=0;d<g;d++)m+=p[d];t.update(m,n,1)}function h(l,p,g,b){if(g===0)return;let m=e.get("WEBGL_multi_draw");if(m===null)for(let d=0;d<l.length;d++)u(l[d]/a,p[d],b[d]);else{m.multiDrawElementsInstancedWEBGL(n,p,0,s,l,0,b,0,g);let d=0;for(let _=0;_<g;_++)d+=p[_]*b[_];t.update(d,n,1)}}this.setMode=r,this.setIndex=o,this.render=c,this.renderInstances=u,this.renderMultiDraw=f,this.renderMultiDrawInstances=h}function rv(i){let e={geometries:0,textures:0},t={frame:0,calls:0,triangles:0,points:0,lines:0};function n(s,a,o){switch(t.calls++,a){case i.TRIANGLES:t.triangles+=o*(s/3);break;case i.LINES:t.lines+=o*(s/2);break;case i.LINE_STRIP:t.lines+=o*(s-1);break;case i.LINE_LOOP:t.lines+=o*s;break;case i.POINTS:t.points+=o*s;break;default:ut("WebGLInfo: Unknown draw mode:",a);break}}function r(){t.calls=0,t.triangles=0,t.points=0,t.lines=0}return{memory:e,render:t,programs:null,autoReset:!0,reset:r,update:n}}function sv(i,e,t){let n=new WeakMap,r=new ht;function s(a,o,c){let u=a.morphTargetInfluences,f=o.morphAttributes.position||o.morphAttributes.normal||o.morphAttributes.color,h=f!==void 0?f.length:0,l=n.get(o);if(l===void 0||l.count!==h){let T=function(){I.dispose(),n.delete(o),o.removeEventListener("dispose",T)};l!==void 0&&l.texture.dispose();let p=o.morphAttributes.position!==void 0,g=o.morphAttributes.normal!==void 0,b=o.morphAttributes.color!==void 0,m=o.morphAttributes.position||[],d=o.morphAttributes.normal||[],_=o.morphAttributes.color||[],y=0;p===!0&&(y=1),g===!0&&(y=2),b===!0&&(y=3);let M=o.attributes.position.count*y,w=1;M>e.maxTextureSize&&(w=Math.ceil(M/e.maxTextureSize),M=e.maxTextureSize);let A=new Float32Array(M*w*4*h),I=new Ri(A,M,w,h);I.type=qe,I.needsUpdate=!0;let D=y*4;for(let S=0;S<h;S++){let P=m[S],L=d[S],O=_[S],H=M*w*4*S;for(let q=0;q<P.count;q++){let Y=q*D;p===!0&&(r.fromBufferAttribute(P,q),A[H+Y+0]=r.x,A[H+Y+1]=r.y,A[H+Y+2]=r.z,A[H+Y+3]=0),g===!0&&(r.fromBufferAttribute(L,q),A[H+Y+4]=r.x,A[H+Y+5]=r.y,A[H+Y+6]=r.z,A[H+Y+7]=0),b===!0&&(r.fromBufferAttribute(O,q),A[H+Y+8]=r.x,A[H+Y+9]=r.y,A[H+Y+10]=r.z,A[H+Y+11]=O.itemSize===4?r.w:1)}}l={count:h,texture:I,size:new Le(M,w)},n.set(o,l),o.addEventListener("dispose",T)}if(a.isInstancedMesh===!0&&a.morphTexture!==null)c.getUniforms().setValue(i,"morphTexture",a.morphTexture,t);else{let p=0;for(let b=0;b<u.length;b++)p+=u[b];let g=o.morphTargetsRelative?1:1-p;c.getUniforms().setValue(i,"morphTargetBaseInfluence",g),c.getUniforms().setValue(i,"morphTargetInfluences",u)}c.getUniforms().setValue(i,"morphTargetsTexture",l.texture,t),c.getUniforms().setValue(i,"morphTargetsTextureSize",l.size)}return{update:s}}function av(i,e,t,n){let r=new WeakMap;function s(c){let u=n.render.frame,f=c.geometry,h=e.get(c,f);if(r.get(h)!==u&&(e.update(h),r.set(h,u)),c.isInstancedMesh&&(c.hasEventListener("dispose",o)===!1&&c.addEventListener("dispose",o),r.get(c)!==u&&(t.update(c.instanceMatrix,i.ARRAY_BUFFER),c.instanceColor!==null&&t.update(c.instanceColor,i.ARRAY_BUFFER),r.set(c,u))),c.isSkinnedMesh){let l=c.skeleton;r.get(l)!==u&&(l.update(),r.set(l,u))}return h}function a(){r=new WeakMap}function o(c){let u=c.target;u.removeEventListener("dispose",o),t.remove(u.instanceMatrix),u.instanceColor!==null&&t.remove(u.instanceColor)}return{update:s,dispose:a}}var _d=new mn,td=new Gs(1,1),yd=new Ri,bd=new co,Sd=new Hs,nd=[],id=[],rd=new Float32Array(16),sd=new Float32Array(9),ad=new Float32Array(4);function ns(i,e,t){let n=i[0];if(n<=0||n>0)return i;let r=e*t,s=nd[r];if(s===void 0&&(s=new Float32Array(r),nd[r]=s),e!==0){n.toArray(s,0);for(let a=1,o=0;a!==e;++a)o+=t,i[a].toArray(s,o)}return s}function Jt(i,e){if(i.length!==e.length)return!1;for(let t=0,n=i.length;t<n;t++)if(i[t]!==e[t])return!1;return!0}function Kt(i,e){for(let t=0,n=e.length;t<n;t++)i[t]=e[t]}function vc(i,e){let t=id[e];t===void 0&&(t=new Int32Array(e),id[e]=t);for(let n=0;n!==e;++n)t[n]=i.allocateTextureUnit();return t}function ov(i,e){let t=this.cache;t[0]!==e&&(i.uniform1f(this.addr,e),t[0]=e)}function cv(i,e){let t=this.cache;if(e.x!==void 0)(t[0]!==e.x||t[1]!==e.y)&&(i.uniform2f(this.addr,e.x,e.y),t[0]=e.x,t[1]=e.y);else{if(Jt(t,e))return;i.uniform2fv(this.addr,e),Kt(t,e)}}function lv(i,e){let t=this.cache;if(e.x!==void 0)(t[0]!==e.x||t[1]!==e.y||t[2]!==e.z)&&(i.uniform3f(this.addr,e.x,e.y,e.z),t[0]=e.x,t[1]=e.y,t[2]=e.z);else if(e.r!==void 0)(t[0]!==e.r||t[1]!==e.g||t[2]!==e.b)&&(i.uniform3f(this.addr,e.r,e.g,e.b),t[0]=e.r,t[1]=e.g,t[2]=e.b);else{if(Jt(t,e))return;i.uniform3fv(this.addr,e),Kt(t,e)}}function uv(i,e){let t=this.cache;if(e.x!==void 0)(t[0]!==e.x||t[1]!==e.y||t[2]!==e.z||t[3]!==e.w)&&(i.uniform4f(this.addr,e.x,e.y,e.z,e.w),t[0]=e.x,t[1]=e.y,t[2]=e.z,t[3]=e.w);else{if(Jt(t,e))return;i.uniform4fv(this.addr,e),Kt(t,e)}}function hv(i,e){let t=this.cache,n=e.elements;if(n===void 0){if(Jt(t,e))return;i.uniformMatrix2fv(this.addr,!1,e),Kt(t,e)}else{if(Jt(t,n))return;ad.set(n),i.uniformMatrix2fv(this.addr,!1,ad),Kt(t,n)}}function fv(i,e){let t=this.cache,n=e.elements;if(n===void 0){if(Jt(t,e))return;i.uniformMatrix3fv(this.addr,!1,e),Kt(t,e)}else{if(Jt(t,n))return;sd.set(n),i.uniformMatrix3fv(this.addr,!1,sd),Kt(t,n)}}function dv(i,e){let t=this.cache,n=e.elements;if(n===void 0){if(Jt(t,e))return;i.uniformMatrix4fv(this.addr,!1,e),Kt(t,e)}else{if(Jt(t,n))return;rd.set(n),i.uniformMatrix4fv(this.addr,!1,rd),Kt(t,n)}}function pv(i,e){let t=this.cache;t[0]!==e&&(i.uniform1i(this.addr,e),t[0]=e)}function mv(i,e){let t=this.cache;if(e.x!==void 0)(t[0]!==e.x||t[1]!==e.y)&&(i.uniform2i(this.addr,e.x,e.y),t[0]=e.x,t[1]=e.y);else{if(Jt(t,e))return;i.uniform2iv(this.addr,e),Kt(t,e)}}function gv(i,e){let t=this.cache;if(e.x!==void 0)(t[0]!==e.x||t[1]!==e.y||t[2]!==e.z)&&(i.uniform3i(this.addr,e.x,e.y,e.z),t[0]=e.x,t[1]=e.y,t[2]=e.z);else{if(Jt(t,e))return;i.uniform3iv(this.addr,e),Kt(t,e)}}function xv(i,e){let t=this.cache;if(e.x!==void 0)(t[0]!==e.x||t[1]!==e.y||t[2]!==e.z||t[3]!==e.w)&&(i.uniform4i(this.addr,e.x,e.y,e.z,e.w),t[0]=e.x,t[1]=e.y,t[2]=e.z,t[3]=e.w);else{if(Jt(t,e))return;i.uniform4iv(this.addr,e),Kt(t,e)}}function vv(i,e){let t=this.cache;t[0]!==e&&(i.uniform1ui(this.addr,e),t[0]=e)}function _v(i,e){let t=this.cache;if(e.x!==void 0)(t[0]!==e.x||t[1]!==e.y)&&(i.uniform2ui(this.addr,e.x,e.y),t[0]=e.x,t[1]=e.y);else{if(Jt(t,e))return;i.uniform2uiv(this.addr,e),Kt(t,e)}}function yv(i,e){let t=this.cache;if(e.x!==void 0)(t[0]!==e.x||t[1]!==e.y||t[2]!==e.z)&&(i.uniform3ui(this.addr,e.x,e.y,e.z),t[0]=e.x,t[1]=e.y,t[2]=e.z);else{if(Jt(t,e))return;i.uniform3uiv(this.addr,e),Kt(t,e)}}function bv(i,e){let t=this.cache;if(e.x!==void 0)(t[0]!==e.x||t[1]!==e.y||t[2]!==e.z||t[3]!==e.w)&&(i.uniform4ui(this.addr,e.x,e.y,e.z,e.w),t[0]=e.x,t[1]=e.y,t[2]=e.z,t[3]=e.w);else{if(Jt(t,e))return;i.uniform4uiv(this.addr,e),Kt(t,e)}}function Sv(i,e,t){let n=this.cache,r=t.allocateTextureUnit();n[0]!==r&&(i.uniform1i(this.addr,r),n[0]=r);let s;this.type===i.SAMPLER_2D_SHADOW?(td.compareFunction=Cu,s=td):s=_d,t.setTexture2D(e||s,r)}function Mv(i,e,t){let n=this.cache,r=t.allocateTextureUnit();n[0]!==r&&(i.uniform1i(this.addr,r),n[0]=r),t.setTexture3D(e||bd,r)}function Tv(i,e,t){let n=this.cache,r=t.allocateTextureUnit();n[0]!==r&&(i.uniform1i(this.addr,r),n[0]=r),t.setTextureCube(e||Sd,r)}function wv(i,e,t){let n=this.cache,r=t.allocateTextureUnit();n[0]!==r&&(i.uniform1i(this.addr,r),n[0]=r),t.setTexture2DArray(e||yd,r)}function Av(i){switch(i){case 5126:return ov;case 35664:return cv;case 35665:return lv;case 35666:return uv;case 35674:return hv;case 35675:return fv;case 35676:return dv;case 5124:case 35670:return pv;case 35667:case 35671:return mv;case 35668:case 35672:return gv;case 35669:case 35673:return xv;case 5125:return vv;case 36294:return _v;case 36295:return yv;case 36296:return bv;case 35678:case 36198:case 36298:case 36306:case 35682:return Sv;case 35679:case 36299:case 36307:return Mv;case 35680:case 36300:case 36308:case 36293:return Tv;case 36289:case 36303:case 36311:case 36292:return wv}}function Ev(i,e){i.uniform1fv(this.addr,e)}function Cv(i,e){let t=ns(e,this.size,2);i.uniform2fv(this.addr,t)}function Rv(i,e){let t=ns(e,this.size,3);i.uniform3fv(this.addr,t)}function Iv(i,e){let t=ns(e,this.size,4);i.uniform4fv(this.addr,t)}function Pv(i,e){let t=ns(e,this.size,4);i.uniformMatrix2fv(this.addr,!1,t)}function Dv(i,e){let t=ns(e,this.size,9);i.uniformMatrix3fv(this.addr,!1,t)}function Fv(i,e){let t=ns(e,this.size,16);i.uniformMatrix4fv(this.addr,!1,t)}function Lv(i,e){i.uniform1iv(this.addr,e)}function Nv(i,e){i.uniform2iv(this.addr,e)}function Uv(i,e){i.uniform3iv(this.addr,e)}function Bv(i,e){i.uniform4iv(this.addr,e)}function Ov(i,e){i.uniform1uiv(this.addr,e)}function zv(i,e){i.uniform2uiv(this.addr,e)}function kv(i,e){i.uniform3uiv(this.addr,e)}function Vv(i,e){i.uniform4uiv(this.addr,e)}function Hv(i,e,t){let n=this.cache,r=e.length,s=vc(t,r);Jt(n,s)||(i.uniform1iv(this.addr,s),Kt(n,s));for(let a=0;a!==r;++a)t.setTexture2D(e[a]||_d,s[a])}function Gv(i,e,t){let n=this.cache,r=e.length,s=vc(t,r);Jt(n,s)||(i.uniform1iv(this.addr,s),Kt(n,s));for(let a=0;a!==r;++a)t.setTexture3D(e[a]||bd,s[a])}function Wv(i,e,t){let n=this.cache,r=e.length,s=vc(t,r);Jt(n,s)||(i.uniform1iv(this.addr,s),Kt(n,s));for(let a=0;a!==r;++a)t.setTextureCube(e[a]||Sd,s[a])}function Xv(i,e,t){let n=this.cache,r=e.length,s=vc(t,r);Jt(n,s)||(i.uniform1iv(this.addr,s),Kt(n,s));for(let a=0;a!==r;++a)t.setTexture2DArray(e[a]||yd,s[a])}function qv(i){switch(i){case 5126:return Ev;case 35664:return Cv;case 35665:return Rv;case 35666:return Iv;case 35674:return Pv;case 35675:return Dv;case 35676:return Fv;case 5124:case 35670:return Lv;case 35667:case 35671:return Nv;case 35668:case 35672:return Uv;case 35669:case 35673:return Bv;case 5125:return Ov;case 36294:return zv;case 36295:return kv;case 36296:return Vv;case 35678:case 36198:case 36298:case 36306:case 35682:return Hv;case 35679:case 36299:case 36307:return Gv;case 35680:case 36300:case 36308:case 36293:return Wv;case 36289:case 36303:case 36311:case 36292:return Xv}}var Vu=class{constructor(e,t,n){this.id=e,this.addr=n,this.cache=[],this.type=t.type,this.setValue=Av(t.type)}},Hu=class{constructor(e,t,n){this.id=e,this.addr=n,this.cache=[],this.type=t.type,this.size=t.size,this.setValue=qv(t.type)}},Gu=class{constructor(e){this.id=e,this.seq=[],this.map={}}setValue(e,t,n){let r=this.seq;for(let s=0,a=r.length;s!==a;++s){let o=r[s];o.setValue(e,t[o.id],n)}}},ku=/(\w+)(\])?(\[|\.)?/g;function od(i,e){i.seq.push(e),i.map[e.id]=e}function Yv(i,e,t){let n=i.name,r=n.length;for(ku.lastIndex=0;;){let s=ku.exec(n),a=ku.lastIndex,o=s[1],c=s[2]==="]",u=s[3];if(c&&(o=o|0),u===void 0||u==="["&&a+2===r){od(t,u===void 0?new Vu(o,i,e):new Hu(o,i,e));break}else{let h=t.map[o];h===void 0&&(h=new Gu(o),od(t,h)),t=h}}}var ts=class{constructor(e,t){this.seq=[],this.map={};let n=e.getProgramParameter(t,e.ACTIVE_UNIFORMS);for(let r=0;r<n;++r){let s=e.getActiveUniform(t,r),a=e.getUniformLocation(t,s.name);Yv(s,a,this)}}setValue(e,t,n,r){let s=this.map[t];s!==void 0&&s.setValue(e,n,r)}setOptional(e,t,n){let r=t[n];r!==void 0&&this.setValue(e,n,r)}static upload(e,t,n,r){for(let s=0,a=t.length;s!==a;++s){let o=t[s],c=n[o.id];c.needsUpdate!==!1&&o.setValue(e,c.value,r)}}static seqWithValue(e,t){let n=[];for(let r=0,s=e.length;r!==s;++r){let a=e[r];a.id in t&&n.push(a)}return n}};function cd(i,e,t){let n=i.createShader(e);return i.shaderSource(n,t),i.compileShader(n),n}var Zv=37297,$v=0;function Jv(i,e){let t=i.split(`
`),n=[],r=Math.max(e-6,0),s=Math.min(e+6,t.length);for(let a=r;a<s;a++){let o=a+1;n.push(`${o===e?">":" "} ${o}: ${t[a]}`)}return n.join(`
`)}var ld=new et;function Kv(i){dt._getMatrix(ld,dt.workingColorSpace,i);let e=`mat3( ${ld.elements.map(t=>t.toFixed(4))} )`;switch(dt.getTransfer(i)){case Ns:return[e,"LinearTransferOETF"];case bt:return[e,"sRGBTransferOETF"];default:return Ze("WebGLProgram: Unsupported color space: ",i),[e,"LinearTransferOETF"]}}function ud(i,e,t){let n=i.getShaderParameter(e,i.COMPILE_STATUS),s=(i.getShaderInfoLog(e)||"").trim();if(n&&s==="")return"";let a=/ERROR: 0:(\d+)/.exec(s);if(a){let o=parseInt(a[1]);return t.toUpperCase()+`

`+s+`

`+Jv(i.getShaderSource(e),o)}else return s}function Qv(i,e){let t=Kv(e);return[`vec4 ${i}( vec4 value ) {`,`	return ${t[1]}( vec4( value.rgb * ${t[0]}, value.a ) );`,"}"].join(`
`)}function jv(i,e){let t;switch(e){case Cf:t="Linear";break;case Rf:t="Reinhard";break;case If:t="Cineon";break;case Fo:t="ACESFilmic";break;case Df:t="AgX";break;case Ff:t="Neutral";break;case Pf:t="Custom";break;default:Ze("WebGLProgram: Unsupported toneMapping:",e),t="Linear"}return"vec3 "+i+"( vec3 color ) { return "+t+"ToneMapping( color ); }"}var dc=new k;function e_(){dt.getLuminanceCoefficients(dc);let i=dc.x.toFixed(4),e=dc.y.toFixed(4),t=dc.z.toFixed(4);return["float luminance( const in vec3 rgb ) {",`	const vec3 weights = vec3( ${i}, ${e}, ${t} );`,"	return dot( weights, rgb );","}"].join(`
`)}function t_(i){return[i.extensionClipCullDistance?"#extension GL_ANGLE_clip_cull_distance : require":"",i.extensionMultiDraw?"#extension GL_ANGLE_multi_draw : require":""].filter(ha).join(`
`)}function n_(i){let e=[];for(let t in i){let n=i[t];n!==!1&&e.push("#define "+t+" "+n)}return e.join(`
`)}function i_(i,e){let t={},n=i.getProgramParameter(e,i.ACTIVE_ATTRIBUTES);for(let r=0;r<n;r++){let s=i.getActiveAttrib(e,r),a=s.name,o=1;s.type===i.FLOAT_MAT2&&(o=2),s.type===i.FLOAT_MAT3&&(o=3),s.type===i.FLOAT_MAT4&&(o=4),t[a]={type:s.type,location:i.getAttribLocation(e,a),locationSize:o}}return t}function ha(i){return i!==""}function hd(i,e){let t=e.numSpotLightShadows+e.numSpotLightMaps-e.numSpotLightShadowsWithMaps;return i.replace(/NUM_DIR_LIGHTS/g,e.numDirLights).replace(/NUM_SPOT_LIGHTS/g,e.numSpotLights).replace(/NUM_SPOT_LIGHT_MAPS/g,e.numSpotLightMaps).replace(/NUM_SPOT_LIGHT_COORDS/g,t).replace(/NUM_RECT_AREA_LIGHTS/g,e.numRectAreaLights).replace(/NUM_POINT_LIGHTS/g,e.numPointLights).replace(/NUM_HEMI_LIGHTS/g,e.numHemiLights).replace(/NUM_DIR_LIGHT_SHADOWS/g,e.numDirLightShadows).replace(/NUM_SPOT_LIGHT_SHADOWS_WITH_MAPS/g,e.numSpotLightShadowsWithMaps).replace(/NUM_SPOT_LIGHT_SHADOWS/g,e.numSpotLightShadows).replace(/NUM_POINT_LIGHT_SHADOWS/g,e.numPointLightShadows)}function fd(i,e){return i.replace(/NUM_CLIPPING_PLANES/g,e.numClippingPlanes).replace(/UNION_CLIPPING_PLANES/g,e.numClippingPlanes-e.numClipIntersection)}var r_=/^[ \t]*#include +<([\w\d./]+)>/gm;function Wu(i){return i.replace(r_,a_)}var s_=new Map;function a_(i,e){let t=rt[e];if(t===void 0){let n=s_.get(e);if(n!==void 0)t=rt[n],Ze('WebGLRenderer: Shader chunk "%s" has been deprecated. Use "%s" instead.',e,n);else throw new Error("Can not resolve #include <"+e+">")}return Wu(t)}var o_=/#pragma unroll_loop_start\s+for\s*\(\s*int\s+i\s*=\s*(\d+)\s*;\s*i\s*<\s*(\d+)\s*;\s*i\s*\+\+\s*\)\s*{([\s\S]+?)}\s+#pragma unroll_loop_end/g;function dd(i){return i.replace(o_,c_)}function c_(i,e,t,n){let r="";for(let s=parseInt(e);s<parseInt(t);s++)r+=n.replace(/\[\s*i\s*\]/g,"[ "+s+" ]").replace(/UNROLLED_LOOP_INDEX/g,s);return r}function pd(i){let e=`precision ${i.precision} float;
	precision ${i.precision} int;
	precision ${i.precision} sampler2D;
	precision ${i.precision} samplerCube;
	precision ${i.precision} sampler3D;
	precision ${i.precision} sampler2DArray;
	precision ${i.precision} sampler2DShadow;
	precision ${i.precision} samplerCubeShadow;
	precision ${i.precision} sampler2DArrayShadow;
	precision ${i.precision} isampler2D;
	precision ${i.precision} isampler3D;
	precision ${i.precision} isamplerCube;
	precision ${i.precision} isampler2DArray;
	precision ${i.precision} usampler2D;
	precision ${i.precision} usampler3D;
	precision ${i.precision} usamplerCube;
	precision ${i.precision} usampler2DArray;
	`;return i.precision==="highp"?e+=`
#define HIGH_PRECISION`:i.precision==="mediump"?e+=`
#define MEDIUM_PRECISION`:i.precision==="lowp"&&(e+=`
#define LOW_PRECISION`),e}function l_(i){let e="SHADOWMAP_TYPE_BASIC";return i.shadowMapType===xu?e="SHADOWMAP_TYPE_PCF":i.shadowMapType===of?e="SHADOWMAP_TYPE_PCF_SOFT":i.shadowMapType===jn&&(e="SHADOWMAP_TYPE_VSM"),e}function u_(i){let e="ENVMAP_TYPE_CUBE";if(i.envMap)switch(i.envMapMode){case ar:case or:e="ENVMAP_TYPE_CUBE";break;case na:e="ENVMAP_TYPE_CUBE_UV";break}return e}function h_(i){let e="ENVMAP_MODE_REFLECTION";if(i.envMap)switch(i.envMapMode){case or:e="ENVMAP_MODE_REFRACTION";break}return e}function f_(i){let e="ENVMAP_BLENDING_NONE";if(i.envMap)switch(i.combine){case yu:e="ENVMAP_BLENDING_MULTIPLY";break;case Af:e="ENVMAP_BLENDING_MIX";break;case Ef:e="ENVMAP_BLENDING_ADD";break}return e}function d_(i){let e=i.envMapCubeUVHeight;if(e===null)return null;let t=Math.log2(e)-2,n=1/e;return{texelWidth:1/(3*Math.max(Math.pow(2,t),112)),texelHeight:n,maxMip:t}}function p_(i,e,t,n){let r=i.getContext(),s=t.defines,a=t.vertexShader,o=t.fragmentShader,c=l_(t),u=u_(t),f=h_(t),h=f_(t),l=d_(t),p=t_(t),g=n_(s),b=r.createProgram(),m,d,_=t.glslVersion?"#version "+t.glslVersion+`
`:"";t.isRawShaderMaterial?(m=["#define SHADER_TYPE "+t.shaderType,"#define SHADER_NAME "+t.shaderName,g].filter(ha).join(`
`),m.length>0&&(m+=`
`),d=["#define SHADER_TYPE "+t.shaderType,"#define SHADER_NAME "+t.shaderName,g].filter(ha).join(`
`),d.length>0&&(d+=`
`)):(m=[pd(t),"#define SHADER_TYPE "+t.shaderType,"#define SHADER_NAME "+t.shaderName,g,t.extensionClipCullDistance?"#define USE_CLIP_DISTANCE":"",t.batching?"#define USE_BATCHING":"",t.batchingColor?"#define USE_BATCHING_COLOR":"",t.instancing?"#define USE_INSTANCING":"",t.instancingColor?"#define USE_INSTANCING_COLOR":"",t.instancingMorph?"#define USE_INSTANCING_MORPH":"",t.useFog&&t.fog?"#define USE_FOG":"",t.useFog&&t.fogExp2?"#define FOG_EXP2":"",t.map?"#define USE_MAP":"",t.envMap?"#define USE_ENVMAP":"",t.envMap?"#define "+f:"",t.lightMap?"#define USE_LIGHTMAP":"",t.aoMap?"#define USE_AOMAP":"",t.bumpMap?"#define USE_BUMPMAP":"",t.normalMap?"#define USE_NORMALMAP":"",t.normalMapObjectSpace?"#define USE_NORMALMAP_OBJECTSPACE":"",t.normalMapTangentSpace?"#define USE_NORMALMAP_TANGENTSPACE":"",t.displacementMap?"#define USE_DISPLACEMENTMAP":"",t.emissiveMap?"#define USE_EMISSIVEMAP":"",t.anisotropy?"#define USE_ANISOTROPY":"",t.anisotropyMap?"#define USE_ANISOTROPYMAP":"",t.clearcoatMap?"#define USE_CLEARCOATMAP":"",t.clearcoatRoughnessMap?"#define USE_CLEARCOAT_ROUGHNESSMAP":"",t.clearcoatNormalMap?"#define USE_CLEARCOAT_NORMALMAP":"",t.iridescenceMap?"#define USE_IRIDESCENCEMAP":"",t.iridescenceThicknessMap?"#define USE_IRIDESCENCE_THICKNESSMAP":"",t.specularMap?"#define USE_SPECULARMAP":"",t.specularColorMap?"#define USE_SPECULAR_COLORMAP":"",t.specularIntensityMap?"#define USE_SPECULAR_INTENSITYMAP":"",t.roughnessMap?"#define USE_ROUGHNESSMAP":"",t.metalnessMap?"#define USE_METALNESSMAP":"",t.alphaMap?"#define USE_ALPHAMAP":"",t.alphaHash?"#define USE_ALPHAHASH":"",t.transmission?"#define USE_TRANSMISSION":"",t.transmissionMap?"#define USE_TRANSMISSIONMAP":"",t.thicknessMap?"#define USE_THICKNESSMAP":"",t.sheenColorMap?"#define USE_SHEEN_COLORMAP":"",t.sheenRoughnessMap?"#define USE_SHEEN_ROUGHNESSMAP":"",t.mapUv?"#define MAP_UV "+t.mapUv:"",t.alphaMapUv?"#define ALPHAMAP_UV "+t.alphaMapUv:"",t.lightMapUv?"#define LIGHTMAP_UV "+t.lightMapUv:"",t.aoMapUv?"#define AOMAP_UV "+t.aoMapUv:"",t.emissiveMapUv?"#define EMISSIVEMAP_UV "+t.emissiveMapUv:"",t.bumpMapUv?"#define BUMPMAP_UV "+t.bumpMapUv:"",t.normalMapUv?"#define NORMALMAP_UV "+t.normalMapUv:"",t.displacementMapUv?"#define DISPLACEMENTMAP_UV "+t.displacementMapUv:"",t.metalnessMapUv?"#define METALNESSMAP_UV "+t.metalnessMapUv:"",t.roughnessMapUv?"#define ROUGHNESSMAP_UV "+t.roughnessMapUv:"",t.anisotropyMapUv?"#define ANISOTROPYMAP_UV "+t.anisotropyMapUv:"",t.clearcoatMapUv?"#define CLEARCOATMAP_UV "+t.clearcoatMapUv:"",t.clearcoatNormalMapUv?"#define CLEARCOAT_NORMALMAP_UV "+t.clearcoatNormalMapUv:"",t.clearcoatRoughnessMapUv?"#define CLEARCOAT_ROUGHNESSMAP_UV "+t.clearcoatRoughnessMapUv:"",t.iridescenceMapUv?"#define IRIDESCENCEMAP_UV "+t.iridescenceMapUv:"",t.iridescenceThicknessMapUv?"#define IRIDESCENCE_THICKNESSMAP_UV "+t.iridescenceThicknessMapUv:"",t.sheenColorMapUv?"#define SHEEN_COLORMAP_UV "+t.sheenColorMapUv:"",t.sheenRoughnessMapUv?"#define SHEEN_ROUGHNESSMAP_UV "+t.sheenRoughnessMapUv:"",t.specularMapUv?"#define SPECULARMAP_UV "+t.specularMapUv:"",t.specularColorMapUv?"#define SPECULAR_COLORMAP_UV "+t.specularColorMapUv:"",t.specularIntensityMapUv?"#define SPECULAR_INTENSITYMAP_UV "+t.specularIntensityMapUv:"",t.transmissionMapUv?"#define TRANSMISSIONMAP_UV "+t.transmissionMapUv:"",t.thicknessMapUv?"#define THICKNESSMAP_UV "+t.thicknessMapUv:"",t.vertexTangents&&t.flatShading===!1?"#define USE_TANGENT":"",t.vertexColors?"#define USE_COLOR":"",t.vertexAlphas?"#define USE_COLOR_ALPHA":"",t.vertexUv1s?"#define USE_UV1":"",t.vertexUv2s?"#define USE_UV2":"",t.vertexUv3s?"#define USE_UV3":"",t.pointsUvs?"#define USE_POINTS_UV":"",t.flatShading?"#define FLAT_SHADED":"",t.skinning?"#define USE_SKINNING":"",t.morphTargets?"#define USE_MORPHTARGETS":"",t.morphNormals&&t.flatShading===!1?"#define USE_MORPHNORMALS":"",t.morphColors?"#define USE_MORPHCOLORS":"",t.morphTargetsCount>0?"#define MORPHTARGETS_TEXTURE_STRIDE "+t.morphTextureStride:"",t.morphTargetsCount>0?"#define MORPHTARGETS_COUNT "+t.morphTargetsCount:"",t.doubleSided?"#define DOUBLE_SIDED":"",t.flipSided?"#define FLIP_SIDED":"",t.shadowMapEnabled?"#define USE_SHADOWMAP":"",t.shadowMapEnabled?"#define "+c:"",t.sizeAttenuation?"#define USE_SIZEATTENUATION":"",t.numLightProbes>0?"#define USE_LIGHT_PROBES":"",t.logarithmicDepthBuffer?"#define USE_LOGARITHMIC_DEPTH_BUFFER":"",t.reversedDepthBuffer?"#define USE_REVERSED_DEPTH_BUFFER":"","uniform mat4 modelMatrix;","uniform mat4 modelViewMatrix;","uniform mat4 projectionMatrix;","uniform mat4 viewMatrix;","uniform mat3 normalMatrix;","uniform vec3 cameraPosition;","uniform bool isOrthographic;","#ifdef USE_INSTANCING","	attribute mat4 instanceMatrix;","#endif","#ifdef USE_INSTANCING_COLOR","	attribute vec3 instanceColor;","#endif","#ifdef USE_INSTANCING_MORPH","	uniform sampler2D morphTexture;","#endif","attribute vec3 position;","attribute vec3 normal;","attribute vec2 uv;","#ifdef USE_UV1","	attribute vec2 uv1;","#endif","#ifdef USE_UV2","	attribute vec2 uv2;","#endif","#ifdef USE_UV3","	attribute vec2 uv3;","#endif","#ifdef USE_TANGENT","	attribute vec4 tangent;","#endif","#if defined( USE_COLOR_ALPHA )","	attribute vec4 color;","#elif defined( USE_COLOR )","	attribute vec3 color;","#endif","#ifdef USE_SKINNING","	attribute vec4 skinIndex;","	attribute vec4 skinWeight;","#endif",`
`].filter(ha).join(`
`),d=[pd(t),"#define SHADER_TYPE "+t.shaderType,"#define SHADER_NAME "+t.shaderName,g,t.useFog&&t.fog?"#define USE_FOG":"",t.useFog&&t.fogExp2?"#define FOG_EXP2":"",t.alphaToCoverage?"#define ALPHA_TO_COVERAGE":"",t.map?"#define USE_MAP":"",t.matcap?"#define USE_MATCAP":"",t.envMap?"#define USE_ENVMAP":"",t.envMap?"#define "+u:"",t.envMap?"#define "+f:"",t.envMap?"#define "+h:"",l?"#define CUBEUV_TEXEL_WIDTH "+l.texelWidth:"",l?"#define CUBEUV_TEXEL_HEIGHT "+l.texelHeight:"",l?"#define CUBEUV_MAX_MIP "+l.maxMip+".0":"",t.lightMap?"#define USE_LIGHTMAP":"",t.aoMap?"#define USE_AOMAP":"",t.bumpMap?"#define USE_BUMPMAP":"",t.normalMap?"#define USE_NORMALMAP":"",t.normalMapObjectSpace?"#define USE_NORMALMAP_OBJECTSPACE":"",t.normalMapTangentSpace?"#define USE_NORMALMAP_TANGENTSPACE":"",t.emissiveMap?"#define USE_EMISSIVEMAP":"",t.anisotropy?"#define USE_ANISOTROPY":"",t.anisotropyMap?"#define USE_ANISOTROPYMAP":"",t.clearcoat?"#define USE_CLEARCOAT":"",t.clearcoatMap?"#define USE_CLEARCOATMAP":"",t.clearcoatRoughnessMap?"#define USE_CLEARCOAT_ROUGHNESSMAP":"",t.clearcoatNormalMap?"#define USE_CLEARCOAT_NORMALMAP":"",t.dispersion?"#define USE_DISPERSION":"",t.iridescence?"#define USE_IRIDESCENCE":"",t.iridescenceMap?"#define USE_IRIDESCENCEMAP":"",t.iridescenceThicknessMap?"#define USE_IRIDESCENCE_THICKNESSMAP":"",t.specularMap?"#define USE_SPECULARMAP":"",t.specularColorMap?"#define USE_SPECULAR_COLORMAP":"",t.specularIntensityMap?"#define USE_SPECULAR_INTENSITYMAP":"",t.roughnessMap?"#define USE_ROUGHNESSMAP":"",t.metalnessMap?"#define USE_METALNESSMAP":"",t.alphaMap?"#define USE_ALPHAMAP":"",t.alphaTest?"#define USE_ALPHATEST":"",t.alphaHash?"#define USE_ALPHAHASH":"",t.sheen?"#define USE_SHEEN":"",t.sheenColorMap?"#define USE_SHEEN_COLORMAP":"",t.sheenRoughnessMap?"#define USE_SHEEN_ROUGHNESSMAP":"",t.transmission?"#define USE_TRANSMISSION":"",t.transmissionMap?"#define USE_TRANSMISSIONMAP":"",t.thicknessMap?"#define USE_THICKNESSMAP":"",t.vertexTangents&&t.flatShading===!1?"#define USE_TANGENT":"",t.vertexColors||t.instancingColor||t.batchingColor?"#define USE_COLOR":"",t.vertexAlphas?"#define USE_COLOR_ALPHA":"",t.vertexUv1s?"#define USE_UV1":"",t.vertexUv2s?"#define USE_UV2":"",t.vertexUv3s?"#define USE_UV3":"",t.pointsUvs?"#define USE_POINTS_UV":"",t.gradientMap?"#define USE_GRADIENTMAP":"",t.flatShading?"#define FLAT_SHADED":"",t.doubleSided?"#define DOUBLE_SIDED":"",t.flipSided?"#define FLIP_SIDED":"",t.shadowMapEnabled?"#define USE_SHADOWMAP":"",t.shadowMapEnabled?"#define "+c:"",t.premultipliedAlpha?"#define PREMULTIPLIED_ALPHA":"",t.numLightProbes>0?"#define USE_LIGHT_PROBES":"",t.decodeVideoTexture?"#define DECODE_VIDEO_TEXTURE":"",t.decodeVideoTextureEmissive?"#define DECODE_VIDEO_TEXTURE_EMISSIVE":"",t.logarithmicDepthBuffer?"#define USE_LOGARITHMIC_DEPTH_BUFFER":"",t.reversedDepthBuffer?"#define USE_REVERSED_DEPTH_BUFFER":"","uniform mat4 viewMatrix;","uniform vec3 cameraPosition;","uniform bool isOrthographic;",t.toneMapping!==qn?"#define TONE_MAPPING":"",t.toneMapping!==qn?rt.tonemapping_pars_fragment:"",t.toneMapping!==qn?jv("toneMapping",t.toneMapping):"",t.dithering?"#define DITHERING":"",t.opaque?"#define OPAQUE":"",rt.colorspace_pars_fragment,Qv("linearToOutputTexel",t.outputColorSpace),e_(),t.useDepthPacking?"#define DEPTH_PACKING "+t.depthPacking:"",`
`].filter(ha).join(`
`)),a=Wu(a),a=hd(a,t),a=fd(a,t),o=Wu(o),o=hd(o,t),o=fd(o,t),a=dd(a),o=dd(o),t.isRawShaderMaterial!==!0&&(_=`#version 300 es
`,m=[p,"#define attribute in","#define varying out","#define texture2D texture"].join(`
`)+`
`+m,d=["#define varying in",t.glslVersion===Ru?"":"layout(location = 0) out highp vec4 pc_fragColor;",t.glslVersion===Ru?"":"#define gl_FragColor pc_fragColor","#define gl_FragDepthEXT gl_FragDepth","#define texture2D texture","#define textureCube texture","#define texture2DProj textureProj","#define texture2DLodEXT textureLod","#define texture2DProjLodEXT textureProjLod","#define textureCubeLodEXT textureLod","#define texture2DGradEXT textureGrad","#define texture2DProjGradEXT textureProjGrad","#define textureCubeGradEXT textureGrad"].join(`
`)+`
`+d);let y=_+m+a,M=_+d+o,w=cd(r,r.VERTEX_SHADER,y),A=cd(r,r.FRAGMENT_SHADER,M);r.attachShader(b,w),r.attachShader(b,A),t.index0AttributeName!==void 0?r.bindAttribLocation(b,0,t.index0AttributeName):t.morphTargets===!0&&r.bindAttribLocation(b,0,"position"),r.linkProgram(b);function I(P){if(i.debug.checkShaderErrors){let L=r.getProgramInfoLog(b)||"",O=r.getShaderInfoLog(w)||"",H=r.getShaderInfoLog(A)||"",q=L.trim(),Y=O.trim(),he=H.trim(),j=!0,le=!0;if(r.getProgramParameter(b,r.LINK_STATUS)===!1)if(j=!1,typeof i.debug.onShaderError=="function")i.debug.onShaderError(r,b,w,A);else{let ce=ud(r,w,"vertex"),we=ud(r,A,"fragment");ut("THREE.WebGLProgram: Shader Error "+r.getError()+" - VALIDATE_STATUS "+r.getProgramParameter(b,r.VALIDATE_STATUS)+`

Material Name: `+P.name+`
Material Type: `+P.type+`

Program Info Log: `+q+`
`+ce+`
`+we)}else q!==""?Ze("WebGLProgram: Program Info Log:",q):(Y===""||he==="")&&(le=!1);le&&(P.diagnostics={runnable:j,programLog:q,vertexShader:{log:Y,prefix:m},fragmentShader:{log:he,prefix:d}})}r.deleteShader(w),r.deleteShader(A),D=new ts(r,b),T=i_(r,b)}let D;this.getUniforms=function(){return D===void 0&&I(this),D};let T;this.getAttributes=function(){return T===void 0&&I(this),T};let S=t.rendererExtensionParallelShaderCompile===!1;return this.isReady=function(){return S===!1&&(S=r.getProgramParameter(b,Zv)),S},this.destroy=function(){n.releaseStatesOfProgram(this),r.deleteProgram(b),this.program=void 0},this.type=t.shaderType,this.name=t.shaderName,this.id=$v++,this.cacheKey=e,this.usedTimes=1,this.program=b,this.vertexShader=w,this.fragmentShader=A,this}var m_=0,Xu=class{constructor(){this.shaderCache=new Map,this.materialCache=new Map}update(e){let t=e.vertexShader,n=e.fragmentShader,r=this._getShaderStage(t),s=this._getShaderStage(n),a=this._getShaderCacheForMaterial(e);return a.has(r)===!1&&(a.add(r),r.usedTimes++),a.has(s)===!1&&(a.add(s),s.usedTimes++),this}remove(e){let t=this.materialCache.get(e);for(let n of t)n.usedTimes--,n.usedTimes===0&&this.shaderCache.delete(n.code);return this.materialCache.delete(e),this}getVertexShaderID(e){return this._getShaderStage(e.vertexShader).id}getFragmentShaderID(e){return this._getShaderStage(e.fragmentShader).id}dispose(){this.shaderCache.clear(),this.materialCache.clear()}_getShaderCacheForMaterial(e){let t=this.materialCache,n=t.get(e);return n===void 0&&(n=new Set,t.set(e,n)),n}_getShaderStage(e){let t=this.shaderCache,n=t.get(e);return n===void 0&&(n=new qu(e),t.set(e,n)),n}},qu=class{constructor(e){this.id=m_++,this.code=e,this.usedTimes=0}};function g_(i,e,t,n,r,s,a){let o=new zs,c=new Xu,u=new Set,f=[],h=r.logarithmicDepthBuffer,l=r.vertexTextures,p=r.precision,g={MeshDepthMaterial:"depth",MeshDistanceMaterial:"distanceRGBA",MeshNormalMaterial:"normal",MeshBasicMaterial:"basic",MeshLambertMaterial:"lambert",MeshPhongMaterial:"phong",MeshToonMaterial:"toon",MeshStandardMaterial:"physical",MeshPhysicalMaterial:"physical",MeshMatcapMaterial:"matcap",LineBasicMaterial:"basic",LineDashedMaterial:"dashed",PointsMaterial:"points",ShadowMaterial:"shadow",SpriteMaterial:"sprite"};function b(T){return u.add(T),T===0?"uv":`uv${T}`}function m(T,S,P,L,O){let H=L.fog,q=O.geometry,Y=T.isMeshStandardMaterial?L.environment:null,he=(T.isMeshStandardMaterial?t:e).get(T.envMap||Y),j=he&&he.mapping===na?he.image.height:null,le=g[T.type];T.precision!==null&&(p=r.getMaxPrecision(T.precision),p!==T.precision&&Ze("WebGLProgram.getParameters:",T.precision,"not supported, using",p,"instead."));let ce=q.morphAttributes.position||q.morphAttributes.normal||q.morphAttributes.color,we=ce!==void 0?ce.length:0,Ce=0;q.morphAttributes.position!==void 0&&(Ce=1),q.morphAttributes.normal!==void 0&&(Ce=2),q.morphAttributes.color!==void 0&&(Ce=3);let ke,ct,nt,K;if(le){let vt=ti[le];ke=vt.vertexShader,ct=vt.fragmentShader}else ke=T.vertexShader,ct=T.fragmentShader,c.update(T),nt=c.getVertexShaderID(T),K=c.getFragmentShaderID(T);let re=i.getRenderTarget(),be=i.state.buffers.depth.getReversed(),We=O.isInstancedMesh===!0,Pe=O.isBatchedMesh===!0,Qe=!!T.map,Rt=!!T.matcap,tt=!!he,wt=!!T.aoMap,G=!!T.lightMap,at=!!T.bumpMap,ot=!!T.normalMap,yt=!!T.displacementMap,Ae=!!T.emissiveMap,It=!!T.metalnessMap,Be=!!T.roughnessMap,$e=T.anisotropy>0,N=T.clearcoat>0,E=T.dispersion>0,$=T.iridescence>0,ie=T.sheen>0,ue=T.transmission>0,te=$e&&!!T.anisotropyMap,Fe=N&&!!T.clearcoatMap,xe=N&&!!T.clearcoatNormalMap,Oe=N&&!!T.clearcoatRoughnessMap,De=$&&!!T.iridescenceMap,fe=$&&!!T.iridescenceThicknessMap,de=ie&&!!T.sheenColorMap,Re=ie&&!!T.sheenRoughnessMap,ze=!!T.specularMap,ve=!!T.specularColorMap,Ie=!!T.specularIntensityMap,V=ue&&!!T.transmissionMap,_e=ue&&!!T.thicknessMap,J=!!T.gradientMap,ge=!!T.alphaMap,me=T.alphaTest>0,se=!!T.alphaHash,Ee=!!T.extensions,Je=qn;T.toneMapped&&(re===null||re.isXRRenderTarget===!0)&&(Je=i.toneMapping);let At={shaderID:le,shaderType:T.type,shaderName:T.name,vertexShader:ke,fragmentShader:ct,defines:T.defines,customVertexShaderID:nt,customFragmentShaderID:K,isRawShaderMaterial:T.isRawShaderMaterial===!0,glslVersion:T.glslVersion,precision:p,batching:Pe,batchingColor:Pe&&O._colorsTexture!==null,instancing:We,instancingColor:We&&O.instanceColor!==null,instancingMorph:We&&O.morphTexture!==null,supportsVertexTextures:l,outputColorSpace:re===null?i.outputColorSpace:re.isXRRenderTarget===!0?re.texture.colorSpace:Gt,alphaToCoverage:!!T.alphaToCoverage,map:Qe,matcap:Rt,envMap:tt,envMapMode:tt&&he.mapping,envMapCubeUVHeight:j,aoMap:wt,lightMap:G,bumpMap:at,normalMap:ot,displacementMap:l&&yt,emissiveMap:Ae,normalMapObjectSpace:ot&&T.normalMapType===Bf,normalMapTangentSpace:ot&&T.normalMapType===Eu,metalnessMap:It,roughnessMap:Be,anisotropy:$e,anisotropyMap:te,clearcoat:N,clearcoatMap:Fe,clearcoatNormalMap:xe,clearcoatRoughnessMap:Oe,dispersion:E,iridescence:$,iridescenceMap:De,iridescenceThicknessMap:fe,sheen:ie,sheenColorMap:de,sheenRoughnessMap:Re,specularMap:ze,specularColorMap:ve,specularIntensityMap:Ie,transmission:ue,transmissionMap:V,thicknessMap:_e,gradientMap:J,opaque:T.transparent===!1&&T.blending===Gn&&T.alphaToCoverage===!1,alphaMap:ge,alphaTest:me,alphaHash:se,combine:T.combine,mapUv:Qe&&b(T.map.channel),aoMapUv:wt&&b(T.aoMap.channel),lightMapUv:G&&b(T.lightMap.channel),bumpMapUv:at&&b(T.bumpMap.channel),normalMapUv:ot&&b(T.normalMap.channel),displacementMapUv:yt&&b(T.displacementMap.channel),emissiveMapUv:Ae&&b(T.emissiveMap.channel),metalnessMapUv:It&&b(T.metalnessMap.channel),roughnessMapUv:Be&&b(T.roughnessMap.channel),anisotropyMapUv:te&&b(T.anisotropyMap.channel),clearcoatMapUv:Fe&&b(T.clearcoatMap.channel),clearcoatNormalMapUv:xe&&b(T.clearcoatNormalMap.channel),clearcoatRoughnessMapUv:Oe&&b(T.clearcoatRoughnessMap.channel),iridescenceMapUv:De&&b(T.iridescenceMap.channel),iridescenceThicknessMapUv:fe&&b(T.iridescenceThicknessMap.channel),sheenColorMapUv:de&&b(T.sheenColorMap.channel),sheenRoughnessMapUv:Re&&b(T.sheenRoughnessMap.channel),specularMapUv:ze&&b(T.specularMap.channel),specularColorMapUv:ve&&b(T.specularColorMap.channel),specularIntensityMapUv:Ie&&b(T.specularIntensityMap.channel),transmissionMapUv:V&&b(T.transmissionMap.channel),thicknessMapUv:_e&&b(T.thicknessMap.channel),alphaMapUv:ge&&b(T.alphaMap.channel),vertexTangents:!!q.attributes.tangent&&(ot||$e),vertexColors:T.vertexColors,vertexAlphas:T.vertexColors===!0&&!!q.attributes.color&&q.attributes.color.itemSize===4,pointsUvs:O.isPoints===!0&&!!q.attributes.uv&&(Qe||ge),fog:!!H,useFog:T.fog===!0,fogExp2:!!H&&H.isFogExp2,flatShading:T.flatShading===!0&&T.wireframe===!1,sizeAttenuation:T.sizeAttenuation===!0,logarithmicDepthBuffer:h,reversedDepthBuffer:be,skinning:O.isSkinnedMesh===!0,morphTargets:q.morphAttributes.position!==void 0,morphNormals:q.morphAttributes.normal!==void 0,morphColors:q.morphAttributes.color!==void 0,morphTargetsCount:we,morphTextureStride:Ce,numDirLights:S.directional.length,numPointLights:S.point.length,numSpotLights:S.spot.length,numSpotLightMaps:S.spotLightMap.length,numRectAreaLights:S.rectArea.length,numHemiLights:S.hemi.length,numDirLightShadows:S.directionalShadowMap.length,numPointLightShadows:S.pointShadowMap.length,numSpotLightShadows:S.spotShadowMap.length,numSpotLightShadowsWithMaps:S.numSpotLightShadowsWithMaps,numLightProbes:S.numLightProbes,numClippingPlanes:a.numPlanes,numClipIntersection:a.numIntersection,dithering:T.dithering,shadowMapEnabled:i.shadowMap.enabled&&P.length>0,shadowMapType:i.shadowMap.type,toneMapping:Je,decodeVideoTexture:Qe&&T.map.isVideoTexture===!0&&dt.getTransfer(T.map.colorSpace)===bt,decodeVideoTextureEmissive:Ae&&T.emissiveMap.isVideoTexture===!0&&dt.getTransfer(T.emissiveMap.colorSpace)===bt,premultipliedAlpha:T.premultipliedAlpha,doubleSided:T.side===fn,flipSided:T.side===Zt,useDepthPacking:T.depthPacking>=0,depthPacking:T.depthPacking||0,index0AttributeName:T.index0AttributeName,extensionClipCullDistance:Ee&&T.extensions.clipCullDistance===!0&&n.has("WEBGL_clip_cull_distance"),extensionMultiDraw:(Ee&&T.extensions.multiDraw===!0||Pe)&&n.has("WEBGL_multi_draw"),rendererExtensionParallelShaderCompile:n.has("KHR_parallel_shader_compile"),customProgramCacheKey:T.customProgramCacheKey()};return At.vertexUv1s=u.has(1),At.vertexUv2s=u.has(2),At.vertexUv3s=u.has(3),u.clear(),At}function d(T){let S=[];if(T.shaderID?S.push(T.shaderID):(S.push(T.customVertexShaderID),S.push(T.customFragmentShaderID)),T.defines!==void 0)for(let P in T.defines)S.push(P),S.push(T.defines[P]);return T.isRawShaderMaterial===!1&&(_(S,T),y(S,T),S.push(i.outputColorSpace)),S.push(T.customProgramCacheKey),S.join()}function _(T,S){T.push(S.precision),T.push(S.outputColorSpace),T.push(S.envMapMode),T.push(S.envMapCubeUVHeight),T.push(S.mapUv),T.push(S.alphaMapUv),T.push(S.lightMapUv),T.push(S.aoMapUv),T.push(S.bumpMapUv),T.push(S.normalMapUv),T.push(S.displacementMapUv),T.push(S.emissiveMapUv),T.push(S.metalnessMapUv),T.push(S.roughnessMapUv),T.push(S.anisotropyMapUv),T.push(S.clearcoatMapUv),T.push(S.clearcoatNormalMapUv),T.push(S.clearcoatRoughnessMapUv),T.push(S.iridescenceMapUv),T.push(S.iridescenceThicknessMapUv),T.push(S.sheenColorMapUv),T.push(S.sheenRoughnessMapUv),T.push(S.specularMapUv),T.push(S.specularColorMapUv),T.push(S.specularIntensityMapUv),T.push(S.transmissionMapUv),T.push(S.thicknessMapUv),T.push(S.combine),T.push(S.fogExp2),T.push(S.sizeAttenuation),T.push(S.morphTargetsCount),T.push(S.morphAttributeCount),T.push(S.numDirLights),T.push(S.numPointLights),T.push(S.numSpotLights),T.push(S.numSpotLightMaps),T.push(S.numHemiLights),T.push(S.numRectAreaLights),T.push(S.numDirLightShadows),T.push(S.numPointLightShadows),T.push(S.numSpotLightShadows),T.push(S.numSpotLightShadowsWithMaps),T.push(S.numLightProbes),T.push(S.shadowMapType),T.push(S.toneMapping),T.push(S.numClippingPlanes),T.push(S.numClipIntersection),T.push(S.depthPacking)}function y(T,S){o.disableAll(),S.supportsVertexTextures&&o.enable(0),S.instancing&&o.enable(1),S.instancingColor&&o.enable(2),S.instancingMorph&&o.enable(3),S.matcap&&o.enable(4),S.envMap&&o.enable(5),S.normalMapObjectSpace&&o.enable(6),S.normalMapTangentSpace&&o.enable(7),S.clearcoat&&o.enable(8),S.iridescence&&o.enable(9),S.alphaTest&&o.enable(10),S.vertexColors&&o.enable(11),S.vertexAlphas&&o.enable(12),S.vertexUv1s&&o.enable(13),S.vertexUv2s&&o.enable(14),S.vertexUv3s&&o.enable(15),S.vertexTangents&&o.enable(16),S.anisotropy&&o.enable(17),S.alphaHash&&o.enable(18),S.batching&&o.enable(19),S.dispersion&&o.enable(20),S.batchingColor&&o.enable(21),S.gradientMap&&o.enable(22),T.push(o.mask),o.disableAll(),S.fog&&o.enable(0),S.useFog&&o.enable(1),S.flatShading&&o.enable(2),S.logarithmicDepthBuffer&&o.enable(3),S.reversedDepthBuffer&&o.enable(4),S.skinning&&o.enable(5),S.morphTargets&&o.enable(6),S.morphNormals&&o.enable(7),S.morphColors&&o.enable(8),S.premultipliedAlpha&&o.enable(9),S.shadowMapEnabled&&o.enable(10),S.doubleSided&&o.enable(11),S.flipSided&&o.enable(12),S.useDepthPacking&&o.enable(13),S.dithering&&o.enable(14),S.transmission&&o.enable(15),S.sheen&&o.enable(16),S.opaque&&o.enable(17),S.pointsUvs&&o.enable(18),S.decodeVideoTexture&&o.enable(19),S.decodeVideoTextureEmissive&&o.enable(20),S.alphaToCoverage&&o.enable(21),T.push(o.mask)}function M(T){let S=g[T.type],P;if(S){let L=ti[S];P=Zf.clone(L.uniforms)}else P=T.uniforms;return P}function w(T,S){let P;for(let L=0,O=f.length;L<O;L++){let H=f[L];if(H.cacheKey===S){P=H,++P.usedTimes;break}}return P===void 0&&(P=new p_(i,S,T,s),f.push(P)),P}function A(T){if(--T.usedTimes===0){let S=f.indexOf(T);f[S]=f[f.length-1],f.pop(),T.destroy()}}function I(T){c.remove(T)}function D(){c.dispose()}return{getParameters:m,getProgramCacheKey:d,getUniforms:M,acquireProgram:w,releaseProgram:A,releaseShaderCache:I,programs:f,dispose:D}}function x_(){let i=new WeakMap;function e(a){return i.has(a)}function t(a){let o=i.get(a);return o===void 0&&(o={},i.set(a,o)),o}function n(a){i.delete(a)}function r(a,o,c){i.get(a)[o]=c}function s(){i=new WeakMap}return{has:e,get:t,remove:n,update:r,dispose:s}}function v_(i,e){return i.groupOrder!==e.groupOrder?i.groupOrder-e.groupOrder:i.renderOrder!==e.renderOrder?i.renderOrder-e.renderOrder:i.material.id!==e.material.id?i.material.id-e.material.id:i.z!==e.z?i.z-e.z:i.id-e.id}function md(i,e){return i.groupOrder!==e.groupOrder?i.groupOrder-e.groupOrder:i.renderOrder!==e.renderOrder?i.renderOrder-e.renderOrder:i.z!==e.z?e.z-i.z:i.id-e.id}function gd(){let i=[],e=0,t=[],n=[],r=[];function s(){e=0,t.length=0,n.length=0,r.length=0}function a(h,l,p,g,b,m){let d=i[e];return d===void 0?(d={id:h.id,object:h,geometry:l,material:p,groupOrder:g,renderOrder:h.renderOrder,z:b,group:m},i[e]=d):(d.id=h.id,d.object=h,d.geometry=l,d.material=p,d.groupOrder=g,d.renderOrder=h.renderOrder,d.z=b,d.group=m),e++,d}function o(h,l,p,g,b,m){let d=a(h,l,p,g,b,m);p.transmission>0?n.push(d):p.transparent===!0?r.push(d):t.push(d)}function c(h,l,p,g,b,m){let d=a(h,l,p,g,b,m);p.transmission>0?n.unshift(d):p.transparent===!0?r.unshift(d):t.unshift(d)}function u(h,l){t.length>1&&t.sort(h||v_),n.length>1&&n.sort(l||md),r.length>1&&r.sort(l||md)}function f(){for(let h=e,l=i.length;h<l;h++){let p=i[h];if(p.id===null)break;p.id=null,p.object=null,p.geometry=null,p.material=null,p.group=null}}return{opaque:t,transmissive:n,transparent:r,init:s,push:o,unshift:c,finish:f,sort:u}}function __(){let i=new WeakMap;function e(n,r){let s=i.get(n),a;return s===void 0?(a=new gd,i.set(n,[a])):r>=s.length?(a=new gd,s.push(a)):a=s[r],a}function t(){i=new WeakMap}return{get:e,dispose:t}}function y_(){let i={};return{get:function(e){if(i[e.id]!==void 0)return i[e.id];let t;switch(e.type){case"DirectionalLight":t={direction:new k,color:new Ye};break;case"SpotLight":t={position:new k,direction:new k,color:new Ye,distance:0,coneCos:0,penumbraCos:0,decay:0};break;case"PointLight":t={position:new k,color:new Ye,distance:0,decay:0};break;case"HemisphereLight":t={direction:new k,skyColor:new Ye,groundColor:new Ye};break;case"RectAreaLight":t={color:new Ye,position:new k,halfWidth:new k,halfHeight:new k};break}return i[e.id]=t,t}}}function b_(){let i={};return{get:function(e){if(i[e.id]!==void 0)return i[e.id];let t;switch(e.type){case"DirectionalLight":t={shadowIntensity:1,shadowBias:0,shadowNormalBias:0,shadowRadius:1,shadowMapSize:new Le};break;case"SpotLight":t={shadowIntensity:1,shadowBias:0,shadowNormalBias:0,shadowRadius:1,shadowMapSize:new Le};break;case"PointLight":t={shadowIntensity:1,shadowBias:0,shadowNormalBias:0,shadowRadius:1,shadowMapSize:new Le,shadowCameraNear:1,shadowCameraFar:1e3};break}return i[e.id]=t,t}}}var S_=0;function M_(i,e){return(e.castShadow?2:0)-(i.castShadow?2:0)+(e.map?1:0)-(i.map?1:0)}function T_(i){let e=new y_,t=b_(),n={version:0,hash:{directionalLength:-1,pointLength:-1,spotLength:-1,rectAreaLength:-1,hemiLength:-1,numDirectionalShadows:-1,numPointShadows:-1,numSpotShadows:-1,numSpotMaps:-1,numLightProbes:-1},ambient:[0,0,0],probe:[],directional:[],directionalShadow:[],directionalShadowMap:[],directionalShadowMatrix:[],spot:[],spotLightMap:[],spotShadow:[],spotShadowMap:[],spotLightMatrix:[],rectArea:[],rectAreaLTC1:null,rectAreaLTC2:null,point:[],pointShadow:[],pointShadowMap:[],pointShadowMatrix:[],hemi:[],numSpotLightShadowsWithMaps:0,numLightProbes:0};for(let u=0;u<9;u++)n.probe.push(new k);let r=new k,s=new Xe,a=new Xe;function o(u){let f=0,h=0,l=0;for(let T=0;T<9;T++)n.probe[T].set(0,0,0);let p=0,g=0,b=0,m=0,d=0,_=0,y=0,M=0,w=0,A=0,I=0;u.sort(M_);for(let T=0,S=u.length;T<S;T++){let P=u[T],L=P.color,O=P.intensity,H=P.distance,q=P.shadow&&P.shadow.map?P.shadow.map.texture:null;if(P.isAmbientLight)f+=L.r*O,h+=L.g*O,l+=L.b*O;else if(P.isLightProbe){for(let Y=0;Y<9;Y++)n.probe[Y].addScaledVector(P.sh.coefficients[Y],O);I++}else if(P.isDirectionalLight){let Y=e.get(P);if(Y.color.copy(P.color).multiplyScalar(P.intensity),P.castShadow){let he=P.shadow,j=t.get(P);j.shadowIntensity=he.intensity,j.shadowBias=he.bias,j.shadowNormalBias=he.normalBias,j.shadowRadius=he.radius,j.shadowMapSize=he.mapSize,n.directionalShadow[p]=j,n.directionalShadowMap[p]=q,n.directionalShadowMatrix[p]=P.shadow.matrix,_++}n.directional[p]=Y,p++}else if(P.isSpotLight){let Y=e.get(P);Y.position.setFromMatrixPosition(P.matrixWorld),Y.color.copy(L).multiplyScalar(O),Y.distance=H,Y.coneCos=Math.cos(P.angle),Y.penumbraCos=Math.cos(P.angle*(1-P.penumbra)),Y.decay=P.decay,n.spot[b]=Y;let he=P.shadow;if(P.map&&(n.spotLightMap[w]=P.map,w++,he.updateMatrices(P),P.castShadow&&A++),n.spotLightMatrix[b]=he.matrix,P.castShadow){let j=t.get(P);j.shadowIntensity=he.intensity,j.shadowBias=he.bias,j.shadowNormalBias=he.normalBias,j.shadowRadius=he.radius,j.shadowMapSize=he.mapSize,n.spotShadow[b]=j,n.spotShadowMap[b]=q,M++}b++}else if(P.isRectAreaLight){let Y=e.get(P);Y.color.copy(L).multiplyScalar(O),Y.halfWidth.set(P.width*.5,0,0),Y.halfHeight.set(0,P.height*.5,0),n.rectArea[m]=Y,m++}else if(P.isPointLight){let Y=e.get(P);if(Y.color.copy(P.color).multiplyScalar(P.intensity),Y.distance=P.distance,Y.decay=P.decay,P.castShadow){let he=P.shadow,j=t.get(P);j.shadowIntensity=he.intensity,j.shadowBias=he.bias,j.shadowNormalBias=he.normalBias,j.shadowRadius=he.radius,j.shadowMapSize=he.mapSize,j.shadowCameraNear=he.camera.near,j.shadowCameraFar=he.camera.far,n.pointShadow[g]=j,n.pointShadowMap[g]=q,n.pointShadowMatrix[g]=P.shadow.matrix,y++}n.point[g]=Y,g++}else if(P.isHemisphereLight){let Y=e.get(P);Y.skyColor.copy(P.color).multiplyScalar(O),Y.groundColor.copy(P.groundColor).multiplyScalar(O),n.hemi[d]=Y,d++}}m>0&&(i.has("OES_texture_float_linear")===!0?(n.rectAreaLTC1=Se.LTC_FLOAT_1,n.rectAreaLTC2=Se.LTC_FLOAT_2):(n.rectAreaLTC1=Se.LTC_HALF_1,n.rectAreaLTC2=Se.LTC_HALF_2)),n.ambient[0]=f,n.ambient[1]=h,n.ambient[2]=l;let D=n.hash;(D.directionalLength!==p||D.pointLength!==g||D.spotLength!==b||D.rectAreaLength!==m||D.hemiLength!==d||D.numDirectionalShadows!==_||D.numPointShadows!==y||D.numSpotShadows!==M||D.numSpotMaps!==w||D.numLightProbes!==I)&&(n.directional.length=p,n.spot.length=b,n.rectArea.length=m,n.point.length=g,n.hemi.length=d,n.directionalShadow.length=_,n.directionalShadowMap.length=_,n.pointShadow.length=y,n.pointShadowMap.length=y,n.spotShadow.length=M,n.spotShadowMap.length=M,n.directionalShadowMatrix.length=_,n.pointShadowMatrix.length=y,n.spotLightMatrix.length=M+w-A,n.spotLightMap.length=w,n.numSpotLightShadowsWithMaps=A,n.numLightProbes=I,D.directionalLength=p,D.pointLength=g,D.spotLength=b,D.rectAreaLength=m,D.hemiLength=d,D.numDirectionalShadows=_,D.numPointShadows=y,D.numSpotShadows=M,D.numSpotMaps=w,D.numLightProbes=I,n.version=S_++)}function c(u,f){let h=0,l=0,p=0,g=0,b=0,m=f.matrixWorldInverse;for(let d=0,_=u.length;d<_;d++){let y=u[d];if(y.isDirectionalLight){let M=n.directional[h];M.direction.setFromMatrixPosition(y.matrixWorld),r.setFromMatrixPosition(y.target.matrixWorld),M.direction.sub(r),M.direction.transformDirection(m),h++}else if(y.isSpotLight){let M=n.spot[p];M.position.setFromMatrixPosition(y.matrixWorld),M.position.applyMatrix4(m),M.direction.setFromMatrixPosition(y.matrixWorld),r.setFromMatrixPosition(y.target.matrixWorld),M.direction.sub(r),M.direction.transformDirection(m),p++}else if(y.isRectAreaLight){let M=n.rectArea[g];M.position.setFromMatrixPosition(y.matrixWorld),M.position.applyMatrix4(m),a.identity(),s.copy(y.matrixWorld),s.premultiply(m),a.extractRotation(s),M.halfWidth.set(y.width*.5,0,0),M.halfHeight.set(0,y.height*.5,0),M.halfWidth.applyMatrix4(a),M.halfHeight.applyMatrix4(a),g++}else if(y.isPointLight){let M=n.point[l];M.position.setFromMatrixPosition(y.matrixWorld),M.position.applyMatrix4(m),l++}else if(y.isHemisphereLight){let M=n.hemi[b];M.direction.setFromMatrixPosition(y.matrixWorld),M.direction.transformDirection(m),b++}}}return{setup:o,setupView:c,state:n}}function xd(i){let e=new T_(i),t=[],n=[];function r(f){u.camera=f,t.length=0,n.length=0}function s(f){t.push(f)}function a(f){n.push(f)}function o(){e.setup(t)}function c(f){e.setupView(t,f)}let u={lightsArray:t,shadowsArray:n,camera:null,lights:e,transmissionRenderTarget:{}};return{init:r,state:u,setupLights:o,setupLightsView:c,pushLight:s,pushShadow:a}}function w_(i){let e=new WeakMap;function t(r,s=0){let a=e.get(r),o;return a===void 0?(o=new xd(i),e.set(r,[o])):s>=a.length?(o=new xd(i),a.push(o)):o=a[s],o}function n(){e=new WeakMap}return{get:t,dispose:n}}var A_=`void main() {
	gl_Position = vec4( position, 1.0 );
}`,E_=`uniform sampler2D shadow_pass;
uniform vec2 resolution;
uniform float radius;
#include <packing>
void main() {
	const float samples = float( VSM_SAMPLES );
	float mean = 0.0;
	float squared_mean = 0.0;
	float uvStride = samples <= 1.0 ? 0.0 : 2.0 / ( samples - 1.0 );
	float uvStart = samples <= 1.0 ? 0.0 : - 1.0;
	for ( float i = 0.0; i < samples; i ++ ) {
		float uvOffset = uvStart + i * uvStride;
		#ifdef HORIZONTAL_PASS
			vec2 distribution = unpackRGBATo2Half( texture2D( shadow_pass, ( gl_FragCoord.xy + vec2( uvOffset, 0.0 ) * radius ) / resolution ) );
			mean += distribution.x;
			squared_mean += distribution.y * distribution.y + distribution.x * distribution.x;
		#else
			float depth = unpackRGBAToDepth( texture2D( shadow_pass, ( gl_FragCoord.xy + vec2( 0.0, uvOffset ) * radius ) / resolution ) );
			mean += depth;
			squared_mean += depth * depth;
		#endif
	}
	mean = mean / samples;
	squared_mean = squared_mean / samples;
	float std_dev = sqrt( squared_mean - mean * mean );
	gl_FragColor = pack2HalfToRGBA( vec2( mean, std_dev ) );
}`;function C_(i,e,t){let n=new Zr,r=new Le,s=new Le,a=new ht,o=new fo({depthPacking:Uf}),c=new po,u={},f=t.maxTextureSize,h={[Mn]:Zt,[Zt]:Mn,[fn]:fn},l=new Xt({defines:{VSM_SAMPLES:8},uniforms:{shadow_pass:{value:null},resolution:{value:new Le},radius:{value:4}},vertexShader:A_,fragmentShader:E_}),p=l.clone();p.defines.HORIZONTAL_PASS=1;let g=new Bt;g.setAttribute("position",new mt(new Float32Array([-1,-1,.5,3,-1,.5,-1,3,.5]),3));let b=new rn(g,l),m=this;this.enabled=!1,this.autoUpdate=!0,this.needsUpdate=!1,this.type=xu;let d=this.type;this.render=function(A,I,D){if(m.enabled===!1||m.autoUpdate===!1&&m.needsUpdate===!1||A.length===0)return;let T=i.getRenderTarget(),S=i.getActiveCubeFace(),P=i.getActiveMipmapLevel(),L=i.state;L.setBlending($t),L.buffers.depth.getReversed()===!0?L.buffers.color.setClear(0,0,0,0):L.buffers.color.setClear(1,1,1,1),L.buffers.depth.setTest(!0),L.setScissorTest(!1);let O=d!==jn&&this.type===jn,H=d===jn&&this.type!==jn;for(let q=0,Y=A.length;q<Y;q++){let he=A[q],j=he.shadow;if(j===void 0){Ze("WebGLShadowMap:",he,"has no shadow.");continue}if(j.autoUpdate===!1&&j.needsUpdate===!1)continue;r.copy(j.mapSize);let le=j.getFrameExtents();if(r.multiply(le),s.copy(j.mapSize),(r.x>f||r.y>f)&&(r.x>f&&(s.x=Math.floor(f/le.x),r.x=s.x*le.x,j.mapSize.x=s.x),r.y>f&&(s.y=Math.floor(f/le.y),r.y=s.y*le.y,j.mapSize.y=s.y)),j.map===null||O===!0||H===!0){let we=this.type!==jn?{minFilter:je,magFilter:je}:{};j.map!==null&&j.map.dispose(),j.map=new Yt(r.x,r.y,we),j.map.texture.name=he.name+".shadowMap",j.camera.updateProjectionMatrix()}i.setRenderTarget(j.map),i.clear();let ce=j.getViewportCount();for(let we=0;we<ce;we++){let Ce=j.getViewport(we);a.set(s.x*Ce.x,s.y*Ce.y,s.x*Ce.z,s.y*Ce.w),L.viewport(a),j.updateMatrices(he,we),n=j.getFrustum(),M(I,D,j.camera,he,this.type)}j.isPointLightShadow!==!0&&this.type===jn&&_(j,D),j.needsUpdate=!1}d=this.type,m.needsUpdate=!1,i.setRenderTarget(T,S,P)};function _(A,I){let D=e.update(b);l.defines.VSM_SAMPLES!==A.blurSamples&&(l.defines.VSM_SAMPLES=A.blurSamples,p.defines.VSM_SAMPLES=A.blurSamples,l.needsUpdate=!0,p.needsUpdate=!0),A.mapPass===null&&(A.mapPass=new Yt(r.x,r.y)),l.uniforms.shadow_pass.value=A.map.texture,l.uniforms.resolution.value=A.mapSize,l.uniforms.radius.value=A.radius,i.setRenderTarget(A.mapPass),i.clear(),i.renderBufferDirect(I,null,D,l,b,null),p.uniforms.shadow_pass.value=A.mapPass.texture,p.uniforms.resolution.value=A.mapSize,p.uniforms.radius.value=A.radius,i.setRenderTarget(A.map),i.clear(),i.renderBufferDirect(I,null,D,p,b,null)}function y(A,I,D,T){let S=null,P=D.isPointLight===!0?A.customDistanceMaterial:A.customDepthMaterial;if(P!==void 0)S=P;else if(S=D.isPointLight===!0?c:o,i.localClippingEnabled&&I.clipShadows===!0&&Array.isArray(I.clippingPlanes)&&I.clippingPlanes.length!==0||I.displacementMap&&I.displacementScale!==0||I.alphaMap&&I.alphaTest>0||I.map&&I.alphaTest>0||I.alphaToCoverage===!0){let L=S.uuid,O=I.uuid,H=u[L];H===void 0&&(H={},u[L]=H);let q=H[O];q===void 0&&(q=S.clone(),H[O]=q,I.addEventListener("dispose",w)),S=q}if(S.visible=I.visible,S.wireframe=I.wireframe,T===jn?S.side=I.shadowSide!==null?I.shadowSide:I.side:S.side=I.shadowSide!==null?I.shadowSide:h[I.side],S.alphaMap=I.alphaMap,S.alphaTest=I.alphaToCoverage===!0?.5:I.alphaTest,S.map=I.map,S.clipShadows=I.clipShadows,S.clippingPlanes=I.clippingPlanes,S.clipIntersection=I.clipIntersection,S.displacementMap=I.displacementMap,S.displacementScale=I.displacementScale,S.displacementBias=I.displacementBias,S.wireframeLinewidth=I.wireframeLinewidth,S.linewidth=I.linewidth,D.isPointLight===!0&&S.isMeshDistanceMaterial===!0){let L=i.properties.get(S);L.light=D}return S}function M(A,I,D,T,S){if(A.visible===!1)return;if(A.layers.test(I.layers)&&(A.isMesh||A.isLine||A.isPoints)&&(A.castShadow||A.receiveShadow&&S===jn)&&(!A.frustumCulled||n.intersectsObject(A))){A.modelViewMatrix.multiplyMatrices(D.matrixWorldInverse,A.matrixWorld);let O=e.update(A),H=A.material;if(Array.isArray(H)){let q=O.groups;for(let Y=0,he=q.length;Y<he;Y++){let j=q[Y],le=H[j.materialIndex];if(le&&le.visible){let ce=y(A,le,T,S);A.onBeforeShadow(i,A,I,D,O,ce,j),i.renderBufferDirect(D,null,O,ce,A,j),A.onAfterShadow(i,A,I,D,O,ce,j)}}}else if(H.visible){let q=y(A,H,T,S);A.onBeforeShadow(i,A,I,D,O,q,null),i.renderBufferDirect(D,null,O,q,A,null),A.onAfterShadow(i,A,I,D,O,q,null)}}let L=A.children;for(let O=0,H=L.length;O<H;O++)M(L[O],I,D,T,S)}function w(A){A.target.removeEventListener("dispose",w);for(let D in u){let T=u[D],S=A.target.uuid;S in T&&(T[S].dispose(),delete T[S])}}}var R_={[Ao]:Eo,[Co]:Po,[Ro]:Do,[er]:Io,[Eo]:Ao,[Po]:Co,[Do]:Ro,[Io]:er};function I_(i,e){function t(){let V=!1,_e=new ht,J=null,ge=new ht(0,0,0,0);return{setMask:function(me){J!==me&&!V&&(i.colorMask(me,me,me,me),J=me)},setLocked:function(me){V=me},setClear:function(me,se,Ee,Je,At){At===!0&&(me*=Je,se*=Je,Ee*=Je),_e.set(me,se,Ee,Je),ge.equals(_e)===!1&&(i.clearColor(me,se,Ee,Je),ge.copy(_e))},reset:function(){V=!1,J=null,ge.set(-1,0,0,0)}}}function n(){let V=!1,_e=!1,J=null,ge=null,me=null;return{setReversed:function(se){if(_e!==se){let Ee=e.get("EXT_clip_control");se?Ee.clipControlEXT(Ee.LOWER_LEFT_EXT,Ee.ZERO_TO_ONE_EXT):Ee.clipControlEXT(Ee.LOWER_LEFT_EXT,Ee.NEGATIVE_ONE_TO_ONE_EXT),_e=se;let Je=me;me=null,this.setClear(Je)}},getReversed:function(){return _e},setTest:function(se){se?re(i.DEPTH_TEST):be(i.DEPTH_TEST)},setMask:function(se){J!==se&&!V&&(i.depthMask(se),J=se)},setFunc:function(se){if(_e&&(se=R_[se]),ge!==se){switch(se){case Ao:i.depthFunc(i.NEVER);break;case Eo:i.depthFunc(i.ALWAYS);break;case Co:i.depthFunc(i.LESS);break;case er:i.depthFunc(i.LEQUAL);break;case Ro:i.depthFunc(i.EQUAL);break;case Io:i.depthFunc(i.GEQUAL);break;case Po:i.depthFunc(i.GREATER);break;case Do:i.depthFunc(i.NOTEQUAL);break;default:i.depthFunc(i.LEQUAL)}ge=se}},setLocked:function(se){V=se},setClear:function(se){me!==se&&(_e&&(se=1-se),i.clearDepth(se),me=se)},reset:function(){V=!1,J=null,ge=null,me=null,_e=!1}}}function r(){let V=!1,_e=null,J=null,ge=null,me=null,se=null,Ee=null,Je=null,At=null;return{setTest:function(vt){V||(vt?re(i.STENCIL_TEST):be(i.STENCIL_TEST))},setMask:function(vt){_e!==vt&&!V&&(i.stencilMask(vt),_e=vt)},setFunc:function(vt,Fn,An){(J!==vt||ge!==Fn||me!==An)&&(i.stencilFunc(vt,Fn,An),J=vt,ge=Fn,me=An)},setOp:function(vt,Fn,An){(se!==vt||Ee!==Fn||Je!==An)&&(i.stencilOp(vt,Fn,An),se=vt,Ee=Fn,Je=An)},setLocked:function(vt){V=vt},setClear:function(vt){At!==vt&&(i.clearStencil(vt),At=vt)},reset:function(){V=!1,_e=null,J=null,ge=null,me=null,se=null,Ee=null,Je=null,At=null}}}let s=new t,a=new n,o=new r,c=new WeakMap,u=new WeakMap,f={},h={},l=new WeakMap,p=[],g=null,b=!1,m=null,d=null,_=null,y=null,M=null,w=null,A=null,I=new Ye(0,0,0),D=0,T=!1,S=null,P=null,L=null,O=null,H=null,q=i.getParameter(i.MAX_COMBINED_TEXTURE_IMAGE_UNITS),Y=!1,he=0,j=i.getParameter(i.VERSION);j.indexOf("WebGL")!==-1?(he=parseFloat(/^WebGL (\d)/.exec(j)[1]),Y=he>=1):j.indexOf("OpenGL ES")!==-1&&(he=parseFloat(/^OpenGL ES (\d)/.exec(j)[1]),Y=he>=2);let le=null,ce={},we=i.getParameter(i.SCISSOR_BOX),Ce=i.getParameter(i.VIEWPORT),ke=new ht().fromArray(we),ct=new ht().fromArray(Ce);function nt(V,_e,J,ge){let me=new Uint8Array(4),se=i.createTexture();i.bindTexture(V,se),i.texParameteri(V,i.TEXTURE_MIN_FILTER,i.NEAREST),i.texParameteri(V,i.TEXTURE_MAG_FILTER,i.NEAREST);for(let Ee=0;Ee<J;Ee++)V===i.TEXTURE_3D||V===i.TEXTURE_2D_ARRAY?i.texImage3D(_e,0,i.RGBA,1,1,ge,0,i.RGBA,i.UNSIGNED_BYTE,me):i.texImage2D(_e+Ee,0,i.RGBA,1,1,0,i.RGBA,i.UNSIGNED_BYTE,me);return se}let K={};K[i.TEXTURE_2D]=nt(i.TEXTURE_2D,i.TEXTURE_2D,1),K[i.TEXTURE_CUBE_MAP]=nt(i.TEXTURE_CUBE_MAP,i.TEXTURE_CUBE_MAP_POSITIVE_X,6),K[i.TEXTURE_2D_ARRAY]=nt(i.TEXTURE_2D_ARRAY,i.TEXTURE_2D_ARRAY,1,1),K[i.TEXTURE_3D]=nt(i.TEXTURE_3D,i.TEXTURE_3D,1,1),s.setClear(0,0,0,1),a.setClear(1),o.setClear(0),re(i.DEPTH_TEST),a.setFunc(er),at(!1),ot(gu),re(i.CULL_FACE),wt($t);function re(V){f[V]!==!0&&(i.enable(V),f[V]=!0)}function be(V){f[V]!==!1&&(i.disable(V),f[V]=!1)}function We(V,_e){return h[V]!==_e?(i.bindFramebuffer(V,_e),h[V]=_e,V===i.DRAW_FRAMEBUFFER&&(h[i.FRAMEBUFFER]=_e),V===i.FRAMEBUFFER&&(h[i.DRAW_FRAMEBUFFER]=_e),!0):!1}function Pe(V,_e){let J=p,ge=!1;if(V){J=l.get(_e),J===void 0&&(J=[],l.set(_e,J));let me=V.textures;if(J.length!==me.length||J[0]!==i.COLOR_ATTACHMENT0){for(let se=0,Ee=me.length;se<Ee;se++)J[se]=i.COLOR_ATTACHMENT0+se;J.length=me.length,ge=!0}}else J[0]!==i.BACK&&(J[0]=i.BACK,ge=!0);ge&&i.drawBuffers(J)}function Qe(V){return g!==V?(i.useProgram(V),g=V,!0):!1}let Rt={[Ei]:i.FUNC_ADD,[lf]:i.FUNC_SUBTRACT,[uf]:i.FUNC_REVERSE_SUBTRACT};Rt[hf]=i.MIN,Rt[ff]=i.MAX;let tt={[df]:i.ZERO,[pf]:i.ONE,[mf]:i.SRC_COLOR,[no]:i.SRC_ALPHA,[bf]:i.SRC_ALPHA_SATURATE,[_f]:i.DST_COLOR,[xf]:i.DST_ALPHA,[gf]:i.ONE_MINUS_SRC_COLOR,[io]:i.ONE_MINUS_SRC_ALPHA,[yf]:i.ONE_MINUS_DST_COLOR,[vf]:i.ONE_MINUS_DST_ALPHA,[Sf]:i.CONSTANT_COLOR,[Mf]:i.ONE_MINUS_CONSTANT_COLOR,[Tf]:i.CONSTANT_ALPHA,[wf]:i.ONE_MINUS_CONSTANT_ALPHA};function wt(V,_e,J,ge,me,se,Ee,Je,At,vt){if(V===$t){b===!0&&(be(i.BLEND),b=!1);return}if(b===!1&&(re(i.BLEND),b=!0),V!==cf){if(V!==m||vt!==T){if((d!==Ei||M!==Ei)&&(i.blendEquation(i.FUNC_ADD),d=Ei,M=Ei),vt)switch(V){case Gn:i.blendFuncSeparate(i.ONE,i.ONE_MINUS_SRC_ALPHA,i.ONE,i.ONE_MINUS_SRC_ALPHA);break;case ta:i.blendFunc(i.ONE,i.ONE);break;case vu:i.blendFuncSeparate(i.ZERO,i.ONE_MINUS_SRC_COLOR,i.ZERO,i.ONE);break;case _u:i.blendFuncSeparate(i.DST_COLOR,i.ONE_MINUS_SRC_ALPHA,i.ZERO,i.ONE);break;default:ut("WebGLState: Invalid blending: ",V);break}else switch(V){case Gn:i.blendFuncSeparate(i.SRC_ALPHA,i.ONE_MINUS_SRC_ALPHA,i.ONE,i.ONE_MINUS_SRC_ALPHA);break;case ta:i.blendFuncSeparate(i.SRC_ALPHA,i.ONE,i.ONE,i.ONE);break;case vu:ut("WebGLState: SubtractiveBlending requires material.premultipliedAlpha = true");break;case _u:ut("WebGLState: MultiplyBlending requires material.premultipliedAlpha = true");break;default:ut("WebGLState: Invalid blending: ",V);break}_=null,y=null,w=null,A=null,I.set(0,0,0),D=0,m=V,T=vt}return}me=me||_e,se=se||J,Ee=Ee||ge,(_e!==d||me!==M)&&(i.blendEquationSeparate(Rt[_e],Rt[me]),d=_e,M=me),(J!==_||ge!==y||se!==w||Ee!==A)&&(i.blendFuncSeparate(tt[J],tt[ge],tt[se],tt[Ee]),_=J,y=ge,w=se,A=Ee),(Je.equals(I)===!1||At!==D)&&(i.blendColor(Je.r,Je.g,Je.b,At),I.copy(Je),D=At),m=V,T=!1}function G(V,_e){V.side===fn?be(i.CULL_FACE):re(i.CULL_FACE);let J=V.side===Zt;_e&&(J=!J),at(J),V.blending===Gn&&V.transparent===!1?wt($t):wt(V.blending,V.blendEquation,V.blendSrc,V.blendDst,V.blendEquationAlpha,V.blendSrcAlpha,V.blendDstAlpha,V.blendColor,V.blendAlpha,V.premultipliedAlpha),a.setFunc(V.depthFunc),a.setTest(V.depthTest),a.setMask(V.depthWrite),s.setMask(V.colorWrite);let ge=V.stencilWrite;o.setTest(ge),ge&&(o.setMask(V.stencilWriteMask),o.setFunc(V.stencilFunc,V.stencilRef,V.stencilFuncMask),o.setOp(V.stencilFail,V.stencilZFail,V.stencilZPass)),Ae(V.polygonOffset,V.polygonOffsetFactor,V.polygonOffsetUnits),V.alphaToCoverage===!0?re(i.SAMPLE_ALPHA_TO_COVERAGE):be(i.SAMPLE_ALPHA_TO_COVERAGE)}function at(V){S!==V&&(V?i.frontFace(i.CW):i.frontFace(i.CCW),S=V)}function ot(V){V!==sf?(re(i.CULL_FACE),V!==P&&(V===gu?i.cullFace(i.BACK):V===af?i.cullFace(i.FRONT):i.cullFace(i.FRONT_AND_BACK))):be(i.CULL_FACE),P=V}function yt(V){V!==L&&(Y&&i.lineWidth(V),L=V)}function Ae(V,_e,J){V?(re(i.POLYGON_OFFSET_FILL),(O!==_e||H!==J)&&(i.polygonOffset(_e,J),O=_e,H=J)):be(i.POLYGON_OFFSET_FILL)}function It(V){V?re(i.SCISSOR_TEST):be(i.SCISSOR_TEST)}function Be(V){V===void 0&&(V=i.TEXTURE0+q-1),le!==V&&(i.activeTexture(V),le=V)}function $e(V,_e,J){J===void 0&&(le===null?J=i.TEXTURE0+q-1:J=le);let ge=ce[J];ge===void 0&&(ge={type:void 0,texture:void 0},ce[J]=ge),(ge.type!==V||ge.texture!==_e)&&(le!==J&&(i.activeTexture(J),le=J),i.bindTexture(V,_e||K[V]),ge.type=V,ge.texture=_e)}function N(){let V=ce[le];V!==void 0&&V.type!==void 0&&(i.bindTexture(V.type,null),V.type=void 0,V.texture=void 0)}function E(){try{i.compressedTexImage2D(...arguments)}catch(V){V("WebGLState:",V)}}function $(){try{i.compressedTexImage3D(...arguments)}catch(V){V("WebGLState:",V)}}function ie(){try{i.texSubImage2D(...arguments)}catch(V){V("WebGLState:",V)}}function ue(){try{i.texSubImage3D(...arguments)}catch(V){V("WebGLState:",V)}}function te(){try{i.compressedTexSubImage2D(...arguments)}catch(V){V("WebGLState:",V)}}function Fe(){try{i.compressedTexSubImage3D(...arguments)}catch(V){V("WebGLState:",V)}}function xe(){try{i.texStorage2D(...arguments)}catch(V){V("WebGLState:",V)}}function Oe(){try{i.texStorage3D(...arguments)}catch(V){V("WebGLState:",V)}}function De(){try{i.texImage2D(...arguments)}catch(V){V("WebGLState:",V)}}function fe(){try{i.texImage3D(...arguments)}catch(V){V("WebGLState:",V)}}function de(V){ke.equals(V)===!1&&(i.scissor(V.x,V.y,V.z,V.w),ke.copy(V))}function Re(V){ct.equals(V)===!1&&(i.viewport(V.x,V.y,V.z,V.w),ct.copy(V))}function ze(V,_e){let J=u.get(_e);J===void 0&&(J=new WeakMap,u.set(_e,J));let ge=J.get(V);ge===void 0&&(ge=i.getUniformBlockIndex(_e,V.name),J.set(V,ge))}function ve(V,_e){let ge=u.get(_e).get(V);c.get(_e)!==ge&&(i.uniformBlockBinding(_e,ge,V.__bindingPointIndex),c.set(_e,ge))}function Ie(){i.disable(i.BLEND),i.disable(i.CULL_FACE),i.disable(i.DEPTH_TEST),i.disable(i.POLYGON_OFFSET_FILL),i.disable(i.SCISSOR_TEST),i.disable(i.STENCIL_TEST),i.disable(i.SAMPLE_ALPHA_TO_COVERAGE),i.blendEquation(i.FUNC_ADD),i.blendFunc(i.ONE,i.ZERO),i.blendFuncSeparate(i.ONE,i.ZERO,i.ONE,i.ZERO),i.blendColor(0,0,0,0),i.colorMask(!0,!0,!0,!0),i.clearColor(0,0,0,0),i.depthMask(!0),i.depthFunc(i.LESS),a.setReversed(!1),i.clearDepth(1),i.stencilMask(4294967295),i.stencilFunc(i.ALWAYS,0,4294967295),i.stencilOp(i.KEEP,i.KEEP,i.KEEP),i.clearStencil(0),i.cullFace(i.BACK),i.frontFace(i.CCW),i.polygonOffset(0,0),i.activeTexture(i.TEXTURE0),i.bindFramebuffer(i.FRAMEBUFFER,null),i.bindFramebuffer(i.DRAW_FRAMEBUFFER,null),i.bindFramebuffer(i.READ_FRAMEBUFFER,null),i.useProgram(null),i.lineWidth(1),i.scissor(0,0,i.canvas.width,i.canvas.height),i.viewport(0,0,i.canvas.width,i.canvas.height),f={},le=null,ce={},h={},l=new WeakMap,p=[],g=null,b=!1,m=null,d=null,_=null,y=null,M=null,w=null,A=null,I=new Ye(0,0,0),D=0,T=!1,S=null,P=null,L=null,O=null,H=null,ke.set(0,0,i.canvas.width,i.canvas.height),ct.set(0,0,i.canvas.width,i.canvas.height),s.reset(),a.reset(),o.reset()}return{buffers:{color:s,depth:a,stencil:o},enable:re,disable:be,bindFramebuffer:We,drawBuffers:Pe,useProgram:Qe,setBlending:wt,setMaterial:G,setFlipSided:at,setCullFace:ot,setLineWidth:yt,setPolygonOffset:Ae,setScissorTest:It,activeTexture:Be,bindTexture:$e,unbindTexture:N,compressedTexImage2D:E,compressedTexImage3D:$,texImage2D:De,texImage3D:fe,updateUBOMapping:ze,uniformBlockBinding:ve,texStorage2D:xe,texStorage3D:Oe,texSubImage2D:ie,texSubImage3D:ue,compressedTexSubImage2D:te,compressedTexSubImage3D:Fe,scissor:de,viewport:Re,reset:Ie}}function P_(i,e,t,n,r,s,a){let o=e.has("WEBGL_multisampled_render_to_texture")?e.get("WEBGL_multisampled_render_to_texture"):null,c=typeof navigator>"u"?!1:/OculusBrowser/g.test(navigator.userAgent),u=new Le,f=new WeakMap,h,l=new WeakMap,p=!1;try{p=typeof OffscreenCanvas<"u"&&new OffscreenCanvas(1,1).getContext("2d")!==null}catch{}function g(N,E){return p?new OffscreenCanvas(N,E):Vr("canvas")}function b(N,E,$){let ie=1,ue=$e(N);if((ue.width>$||ue.height>$)&&(ie=$/Math.max(ue.width,ue.height)),ie<1)if(typeof HTMLImageElement<"u"&&N instanceof HTMLImageElement||typeof HTMLCanvasElement<"u"&&N instanceof HTMLCanvasElement||typeof ImageBitmap<"u"&&N instanceof ImageBitmap||typeof VideoFrame<"u"&&N instanceof VideoFrame){let te=Math.floor(ie*ue.width),Fe=Math.floor(ie*ue.height);h===void 0&&(h=g(te,Fe));let xe=E?g(te,Fe):h;return xe.width=te,xe.height=Fe,xe.getContext("2d").drawImage(N,0,0,te,Fe),Ze("WebGLRenderer: Texture has been resized from ("+ue.width+"x"+ue.height+") to ("+te+"x"+Fe+")."),xe}else return"data"in N&&Ze("WebGLRenderer: Image in DataTexture is too big ("+ue.width+"x"+ue.height+")."),N;return N}function m(N){return N.generateMipmaps}function d(N){i.generateMipmap(N)}function _(N){return N.isWebGLCubeRenderTarget?i.TEXTURE_CUBE_MAP:N.isWebGL3DRenderTarget?i.TEXTURE_3D:N.isWebGLArrayRenderTarget||N.isCompressedArrayTexture?i.TEXTURE_2D_ARRAY:i.TEXTURE_2D}function y(N,E,$,ie,ue=!1){if(N!==null){if(i[N]!==void 0)return i[N];Ze("WebGLRenderer: Attempt to use non-existing WebGL internal format '"+N+"'")}let te=E;if(E===i.RED&&($===i.FLOAT&&(te=i.R32F),$===i.HALF_FLOAT&&(te=i.R16F),$===i.UNSIGNED_BYTE&&(te=i.R8)),E===i.RED_INTEGER&&($===i.UNSIGNED_BYTE&&(te=i.R8UI),$===i.UNSIGNED_SHORT&&(te=i.R16UI),$===i.UNSIGNED_INT&&(te=i.R32UI),$===i.BYTE&&(te=i.R8I),$===i.SHORT&&(te=i.R16I),$===i.INT&&(te=i.R32I)),E===i.RG&&($===i.FLOAT&&(te=i.RG32F),$===i.HALF_FLOAT&&(te=i.RG16F),$===i.UNSIGNED_BYTE&&(te=i.RG8)),E===i.RG_INTEGER&&($===i.UNSIGNED_BYTE&&(te=i.RG8UI),$===i.UNSIGNED_SHORT&&(te=i.RG16UI),$===i.UNSIGNED_INT&&(te=i.RG32UI),$===i.BYTE&&(te=i.RG8I),$===i.SHORT&&(te=i.RG16I),$===i.INT&&(te=i.RG32I)),E===i.RGB_INTEGER&&($===i.UNSIGNED_BYTE&&(te=i.RGB8UI),$===i.UNSIGNED_SHORT&&(te=i.RGB16UI),$===i.UNSIGNED_INT&&(te=i.RGB32UI),$===i.BYTE&&(te=i.RGB8I),$===i.SHORT&&(te=i.RGB16I),$===i.INT&&(te=i.RGB32I)),E===i.RGBA_INTEGER&&($===i.UNSIGNED_BYTE&&(te=i.RGBA8UI),$===i.UNSIGNED_SHORT&&(te=i.RGBA16UI),$===i.UNSIGNED_INT&&(te=i.RGBA32UI),$===i.BYTE&&(te=i.RGBA8I),$===i.SHORT&&(te=i.RGBA16I),$===i.INT&&(te=i.RGBA32I)),E===i.RGB&&($===i.UNSIGNED_INT_5_9_9_9_REV&&(te=i.RGB9_E5),$===i.UNSIGNED_INT_10F_11F_11F_REV&&(te=i.R11F_G11F_B10F)),E===i.RGBA){let Fe=ue?Ns:dt.getTransfer(ie);$===i.FLOAT&&(te=i.RGBA32F),$===i.HALF_FLOAT&&(te=i.RGBA16F),$===i.UNSIGNED_BYTE&&(te=Fe===bt?i.SRGB8_ALPHA8:i.RGBA8),$===i.UNSIGNED_SHORT_4_4_4_4&&(te=i.RGBA4),$===i.UNSIGNED_SHORT_5_5_5_1&&(te=i.RGB5_A1)}return(te===i.R16F||te===i.R32F||te===i.RG16F||te===i.RG32F||te===i.RGBA16F||te===i.RGBA32F)&&e.get("EXT_color_buffer_float"),te}function M(N,E){let $;return N?E===null||E===xn||E===Kr?$=i.DEPTH24_STENCIL8:E===qe?$=i.DEPTH32F_STENCIL8:E===Li&&($=i.DEPTH24_STENCIL8,Ze("DepthTexture: 16 bit depth attachment is not supported with stencil. Using 24-bit attachment.")):E===null||E===xn||E===Kr?$=i.DEPTH_COMPONENT24:E===qe?$=i.DEPTH_COMPONENT32F:E===Li&&($=i.DEPTH_COMPONENT16),$}function w(N,E){return m(N)===!0||N.isFramebufferTexture&&N.minFilter!==je&&N.minFilter!==ft?Math.log2(Math.max(E.width,E.height))+1:N.mipmaps!==void 0&&N.mipmaps.length>0?N.mipmaps.length:N.isCompressedTexture&&Array.isArray(N.image)?E.mipmaps.length:1}function A(N){let E=N.target;E.removeEventListener("dispose",A),D(E),E.isVideoTexture&&f.delete(E)}function I(N){let E=N.target;E.removeEventListener("dispose",I),S(E)}function D(N){let E=n.get(N);if(E.__webglInit===void 0)return;let $=N.source,ie=l.get($);if(ie){let ue=ie[E.__cacheKey];ue.usedTimes--,ue.usedTimes===0&&T(N),Object.keys(ie).length===0&&l.delete($)}n.remove(N)}function T(N){let E=n.get(N);i.deleteTexture(E.__webglTexture);let $=N.source,ie=l.get($);delete ie[E.__cacheKey],a.memory.textures--}function S(N){let E=n.get(N);if(N.depthTexture&&(N.depthTexture.dispose(),n.remove(N.depthTexture)),N.isWebGLCubeRenderTarget)for(let ie=0;ie<6;ie++){if(Array.isArray(E.__webglFramebuffer[ie]))for(let ue=0;ue<E.__webglFramebuffer[ie].length;ue++)i.deleteFramebuffer(E.__webglFramebuffer[ie][ue]);else i.deleteFramebuffer(E.__webglFramebuffer[ie]);E.__webglDepthbuffer&&i.deleteRenderbuffer(E.__webglDepthbuffer[ie])}else{if(Array.isArray(E.__webglFramebuffer))for(let ie=0;ie<E.__webglFramebuffer.length;ie++)i.deleteFramebuffer(E.__webglFramebuffer[ie]);else i.deleteFramebuffer(E.__webglFramebuffer);if(E.__webglDepthbuffer&&i.deleteRenderbuffer(E.__webglDepthbuffer),E.__webglMultisampledFramebuffer&&i.deleteFramebuffer(E.__webglMultisampledFramebuffer),E.__webglColorRenderbuffer)for(let ie=0;ie<E.__webglColorRenderbuffer.length;ie++)E.__webglColorRenderbuffer[ie]&&i.deleteRenderbuffer(E.__webglColorRenderbuffer[ie]);E.__webglDepthRenderbuffer&&i.deleteRenderbuffer(E.__webglDepthRenderbuffer)}let $=N.textures;for(let ie=0,ue=$.length;ie<ue;ie++){let te=n.get($[ie]);te.__webglTexture&&(i.deleteTexture(te.__webglTexture),a.memory.textures--),n.remove($[ie])}n.remove(N)}let P=0;function L(){P=0}function O(){let N=P;return N>=r.maxTextures&&Ze("WebGLTextures: Trying to use "+N+" texture units while this GPU supports only "+r.maxTextures),P+=1,N}function H(N){let E=[];return E.push(N.wrapS),E.push(N.wrapT),E.push(N.wrapR||0),E.push(N.magFilter),E.push(N.minFilter),E.push(N.anisotropy),E.push(N.internalFormat),E.push(N.format),E.push(N.type),E.push(N.generateMipmaps),E.push(N.premultiplyAlpha),E.push(N.flipY),E.push(N.unpackAlignment),E.push(N.colorSpace),E.join()}function q(N,E){let $=n.get(N);if(N.isVideoTexture&&It(N),N.isRenderTargetTexture===!1&&N.isExternalTexture!==!0&&N.version>0&&$.__version!==N.version){let ie=N.image;if(ie===null)Ze("WebGLRenderer: Texture marked for update but no image data found.");else if(ie.complete===!1)Ze("WebGLRenderer: Texture marked for update but image is incomplete");else{K($,N,E);return}}else N.isExternalTexture&&($.__webglTexture=N.sourceTexture?N.sourceTexture:null);t.bindTexture(i.TEXTURE_2D,$.__webglTexture,i.TEXTURE0+E)}function Y(N,E){let $=n.get(N);if(N.isRenderTargetTexture===!1&&N.version>0&&$.__version!==N.version){K($,N,E);return}else N.isExternalTexture&&($.__webglTexture=N.sourceTexture?N.sourceTexture:null);t.bindTexture(i.TEXTURE_2D_ARRAY,$.__webglTexture,i.TEXTURE0+E)}function he(N,E){let $=n.get(N);if(N.isRenderTargetTexture===!1&&N.version>0&&$.__version!==N.version){K($,N,E);return}t.bindTexture(i.TEXTURE_3D,$.__webglTexture,i.TEXTURE0+E)}function j(N,E){let $=n.get(N);if(N.version>0&&$.__version!==N.version){re($,N,E);return}t.bindTexture(i.TEXTURE_CUBE_MAP,$.__webglTexture,i.TEXTURE0+E)}let le={[hn]:i.REPEAT,[Lt]:i.CLAMP_TO_EDGE,[ro]:i.MIRRORED_REPEAT},ce={[je]:i.NEAREST,[Lf]:i.NEAREST_MIPMAP_NEAREST,[ia]:i.NEAREST_MIPMAP_LINEAR,[ft]:i.LINEAR,[No]:i.LINEAR_MIPMAP_NEAREST,[mi]:i.LINEAR_MIPMAP_LINEAR},we={[Of]:i.NEVER,[Wf]:i.ALWAYS,[zf]:i.LESS,[Cu]:i.LEQUAL,[kf]:i.EQUAL,[Gf]:i.GEQUAL,[Vf]:i.GREATER,[Hf]:i.NOTEQUAL};function Ce(N,E){if(E.type===qe&&e.has("OES_texture_float_linear")===!1&&(E.magFilter===ft||E.magFilter===No||E.magFilter===ia||E.magFilter===mi||E.minFilter===ft||E.minFilter===No||E.minFilter===ia||E.minFilter===mi)&&Ze("WebGLRenderer: Unable to use linear filtering with floating point textures. OES_texture_float_linear not supported on this device."),i.texParameteri(N,i.TEXTURE_WRAP_S,le[E.wrapS]),i.texParameteri(N,i.TEXTURE_WRAP_T,le[E.wrapT]),(N===i.TEXTURE_3D||N===i.TEXTURE_2D_ARRAY)&&i.texParameteri(N,i.TEXTURE_WRAP_R,le[E.wrapR]),i.texParameteri(N,i.TEXTURE_MAG_FILTER,ce[E.magFilter]),i.texParameteri(N,i.TEXTURE_MIN_FILTER,ce[E.minFilter]),E.compareFunction&&(i.texParameteri(N,i.TEXTURE_COMPARE_MODE,i.COMPARE_REF_TO_TEXTURE),i.texParameteri(N,i.TEXTURE_COMPARE_FUNC,we[E.compareFunction])),e.has("EXT_texture_filter_anisotropic")===!0){if(E.magFilter===je||E.minFilter!==ia&&E.minFilter!==mi||E.type===qe&&e.has("OES_texture_float_linear")===!1)return;if(E.anisotropy>1||n.get(E).__currentAnisotropy){let $=e.get("EXT_texture_filter_anisotropic");i.texParameterf(N,$.TEXTURE_MAX_ANISOTROPY_EXT,Math.min(E.anisotropy,r.getMaxAnisotropy())),n.get(E).__currentAnisotropy=E.anisotropy}}}function ke(N,E){let $=!1;N.__webglInit===void 0&&(N.__webglInit=!0,E.addEventListener("dispose",A));let ie=E.source,ue=l.get(ie);ue===void 0&&(ue={},l.set(ie,ue));let te=H(E);if(te!==N.__cacheKey){ue[te]===void 0&&(ue[te]={texture:i.createTexture(),usedTimes:0},a.memory.textures++,$=!0),ue[te].usedTimes++;let Fe=ue[N.__cacheKey];Fe!==void 0&&(ue[N.__cacheKey].usedTimes--,Fe.usedTimes===0&&T(E)),N.__cacheKey=te,N.__webglTexture=ue[te].texture}return $}function ct(N,E,$){return Math.floor(Math.floor(N/$)/E)}function nt(N,E,$,ie){let te=N.updateRanges;if(te.length===0)t.texSubImage2D(i.TEXTURE_2D,0,0,0,E.width,E.height,$,ie,E.data);else{te.sort((fe,de)=>fe.start-de.start);let Fe=0;for(let fe=1;fe<te.length;fe++){let de=te[Fe],Re=te[fe],ze=de.start+de.count,ve=ct(Re.start,E.width,4),Ie=ct(de.start,E.width,4);Re.start<=ze+1&&ve===Ie&&ct(Re.start+Re.count-1,E.width,4)===ve?de.count=Math.max(de.count,Re.start+Re.count-de.start):(++Fe,te[Fe]=Re)}te.length=Fe+1;let xe=i.getParameter(i.UNPACK_ROW_LENGTH),Oe=i.getParameter(i.UNPACK_SKIP_PIXELS),De=i.getParameter(i.UNPACK_SKIP_ROWS);i.pixelStorei(i.UNPACK_ROW_LENGTH,E.width);for(let fe=0,de=te.length;fe<de;fe++){let Re=te[fe],ze=Math.floor(Re.start/4),ve=Math.ceil(Re.count/4),Ie=ze%E.width,V=Math.floor(ze/E.width),_e=ve,J=1;i.pixelStorei(i.UNPACK_SKIP_PIXELS,Ie),i.pixelStorei(i.UNPACK_SKIP_ROWS,V),t.texSubImage2D(i.TEXTURE_2D,0,Ie,V,_e,J,$,ie,E.data)}N.clearUpdateRanges(),i.pixelStorei(i.UNPACK_ROW_LENGTH,xe),i.pixelStorei(i.UNPACK_SKIP_PIXELS,Oe),i.pixelStorei(i.UNPACK_SKIP_ROWS,De)}}function K(N,E,$){let ie=i.TEXTURE_2D;(E.isDataArrayTexture||E.isCompressedArrayTexture)&&(ie=i.TEXTURE_2D_ARRAY),E.isData3DTexture&&(ie=i.TEXTURE_3D);let ue=ke(N,E),te=E.source;t.bindTexture(ie,N.__webglTexture,i.TEXTURE0+$);let Fe=n.get(te);if(te.version!==Fe.__version||ue===!0){t.activeTexture(i.TEXTURE0+$);let xe=dt.getPrimaries(dt.workingColorSpace),Oe=E.colorSpace===gi?null:dt.getPrimaries(E.colorSpace),De=E.colorSpace===gi||xe===Oe?i.NONE:i.BROWSER_DEFAULT_WEBGL;i.pixelStorei(i.UNPACK_FLIP_Y_WEBGL,E.flipY),i.pixelStorei(i.UNPACK_PREMULTIPLY_ALPHA_WEBGL,E.premultiplyAlpha),i.pixelStorei(i.UNPACK_ALIGNMENT,E.unpackAlignment),i.pixelStorei(i.UNPACK_COLORSPACE_CONVERSION_WEBGL,De);let fe=b(E.image,!1,r.maxTextureSize);fe=Be(E,fe);let de=s.convert(E.format,E.colorSpace),Re=s.convert(E.type),ze=y(E.internalFormat,de,Re,E.colorSpace,E.isVideoTexture);Ce(ie,E);let ve,Ie=E.mipmaps,V=E.isVideoTexture!==!0,_e=Fe.__version===void 0||ue===!0,J=te.dataReady,ge=w(E,fe);if(E.isDepthTexture)ze=M(E.format===Qr,E.type),_e&&(V?t.texStorage2D(i.TEXTURE_2D,1,ze,fe.width,fe.height):t.texImage2D(i.TEXTURE_2D,0,ze,fe.width,fe.height,0,de,Re,null));else if(E.isDataTexture)if(Ie.length>0){V&&_e&&t.texStorage2D(i.TEXTURE_2D,ge,ze,Ie[0].width,Ie[0].height);for(let me=0,se=Ie.length;me<se;me++)ve=Ie[me],V?J&&t.texSubImage2D(i.TEXTURE_2D,me,0,0,ve.width,ve.height,de,Re,ve.data):t.texImage2D(i.TEXTURE_2D,me,ze,ve.width,ve.height,0,de,Re,ve.data);E.generateMipmaps=!1}else V?(_e&&t.texStorage2D(i.TEXTURE_2D,ge,ze,fe.width,fe.height),J&&nt(E,fe,de,Re)):t.texImage2D(i.TEXTURE_2D,0,ze,fe.width,fe.height,0,de,Re,fe.data);else if(E.isCompressedTexture)if(E.isCompressedArrayTexture){V&&_e&&t.texStorage3D(i.TEXTURE_2D_ARRAY,ge,ze,Ie[0].width,Ie[0].height,fe.depth);for(let me=0,se=Ie.length;me<se;me++)if(ve=Ie[me],E.format!==He)if(de!==null)if(V){if(J)if(E.layerUpdates.size>0){let Ee=Nu(ve.width,ve.height,E.format,E.type);for(let Je of E.layerUpdates){let At=ve.data.subarray(Je*Ee/ve.data.BYTES_PER_ELEMENT,(Je+1)*Ee/ve.data.BYTES_PER_ELEMENT);t.compressedTexSubImage3D(i.TEXTURE_2D_ARRAY,me,0,0,Je,ve.width,ve.height,1,de,At)}E.clearLayerUpdates()}else t.compressedTexSubImage3D(i.TEXTURE_2D_ARRAY,me,0,0,0,ve.width,ve.height,fe.depth,de,ve.data)}else t.compressedTexImage3D(i.TEXTURE_2D_ARRAY,me,ze,ve.width,ve.height,fe.depth,0,ve.data,0,0);else Ze("WebGLRenderer: Attempt to load unsupported compressed texture format in .uploadTexture()");else V?J&&t.texSubImage3D(i.TEXTURE_2D_ARRAY,me,0,0,0,ve.width,ve.height,fe.depth,de,Re,ve.data):t.texImage3D(i.TEXTURE_2D_ARRAY,me,ze,ve.width,ve.height,fe.depth,0,de,Re,ve.data)}else{V&&_e&&t.texStorage2D(i.TEXTURE_2D,ge,ze,Ie[0].width,Ie[0].height);for(let me=0,se=Ie.length;me<se;me++)ve=Ie[me],E.format!==He?de!==null?V?J&&t.compressedTexSubImage2D(i.TEXTURE_2D,me,0,0,ve.width,ve.height,de,ve.data):t.compressedTexImage2D(i.TEXTURE_2D,me,ze,ve.width,ve.height,0,ve.data):Ze("WebGLRenderer: Attempt to load unsupported compressed texture format in .uploadTexture()"):V?J&&t.texSubImage2D(i.TEXTURE_2D,me,0,0,ve.width,ve.height,de,Re,ve.data):t.texImage2D(i.TEXTURE_2D,me,ze,ve.width,ve.height,0,de,Re,ve.data)}else if(E.isDataArrayTexture)if(V){if(_e&&t.texStorage3D(i.TEXTURE_2D_ARRAY,ge,ze,fe.width,fe.height,fe.depth),J)if(E.layerUpdates.size>0){let me=Nu(fe.width,fe.height,E.format,E.type);for(let se of E.layerUpdates){let Ee=fe.data.subarray(se*me/fe.data.BYTES_PER_ELEMENT,(se+1)*me/fe.data.BYTES_PER_ELEMENT);t.texSubImage3D(i.TEXTURE_2D_ARRAY,0,0,0,se,fe.width,fe.height,1,de,Re,Ee)}E.clearLayerUpdates()}else t.texSubImage3D(i.TEXTURE_2D_ARRAY,0,0,0,0,fe.width,fe.height,fe.depth,de,Re,fe.data)}else t.texImage3D(i.TEXTURE_2D_ARRAY,0,ze,fe.width,fe.height,fe.depth,0,de,Re,fe.data);else if(E.isData3DTexture)V?(_e&&t.texStorage3D(i.TEXTURE_3D,ge,ze,fe.width,fe.height,fe.depth),J&&t.texSubImage3D(i.TEXTURE_3D,0,0,0,0,fe.width,fe.height,fe.depth,de,Re,fe.data)):t.texImage3D(i.TEXTURE_3D,0,ze,fe.width,fe.height,fe.depth,0,de,Re,fe.data);else if(E.isFramebufferTexture){if(_e)if(V)t.texStorage2D(i.TEXTURE_2D,ge,ze,fe.width,fe.height);else{let me=fe.width,se=fe.height;for(let Ee=0;Ee<ge;Ee++)t.texImage2D(i.TEXTURE_2D,Ee,ze,me,se,0,de,Re,null),me>>=1,se>>=1}}else if(Ie.length>0){if(V&&_e){let me=$e(Ie[0]);t.texStorage2D(i.TEXTURE_2D,ge,ze,me.width,me.height)}for(let me=0,se=Ie.length;me<se;me++)ve=Ie[me],V?J&&t.texSubImage2D(i.TEXTURE_2D,me,0,0,de,Re,ve):t.texImage2D(i.TEXTURE_2D,me,ze,de,Re,ve);E.generateMipmaps=!1}else if(V){if(_e){let me=$e(fe);t.texStorage2D(i.TEXTURE_2D,ge,ze,me.width,me.height)}J&&t.texSubImage2D(i.TEXTURE_2D,0,0,0,de,Re,fe)}else t.texImage2D(i.TEXTURE_2D,0,ze,de,Re,fe);m(E)&&d(ie),Fe.__version=te.version,E.onUpdate&&E.onUpdate(E)}N.__version=E.version}function re(N,E,$){if(E.image.length!==6)return;let ie=ke(N,E),ue=E.source;t.bindTexture(i.TEXTURE_CUBE_MAP,N.__webglTexture,i.TEXTURE0+$);let te=n.get(ue);if(ue.version!==te.__version||ie===!0){t.activeTexture(i.TEXTURE0+$);let Fe=dt.getPrimaries(dt.workingColorSpace),xe=E.colorSpace===gi?null:dt.getPrimaries(E.colorSpace),Oe=E.colorSpace===gi||Fe===xe?i.NONE:i.BROWSER_DEFAULT_WEBGL;i.pixelStorei(i.UNPACK_FLIP_Y_WEBGL,E.flipY),i.pixelStorei(i.UNPACK_PREMULTIPLY_ALPHA_WEBGL,E.premultiplyAlpha),i.pixelStorei(i.UNPACK_ALIGNMENT,E.unpackAlignment),i.pixelStorei(i.UNPACK_COLORSPACE_CONVERSION_WEBGL,Oe);let De=E.isCompressedTexture||E.image[0].isCompressedTexture,fe=E.image[0]&&E.image[0].isDataTexture,de=[];for(let se=0;se<6;se++)!De&&!fe?de[se]=b(E.image[se],!0,r.maxCubemapSize):de[se]=fe?E.image[se].image:E.image[se],de[se]=Be(E,de[se]);let Re=de[0],ze=s.convert(E.format,E.colorSpace),ve=s.convert(E.type),Ie=y(E.internalFormat,ze,ve,E.colorSpace),V=E.isVideoTexture!==!0,_e=te.__version===void 0||ie===!0,J=ue.dataReady,ge=w(E,Re);Ce(i.TEXTURE_CUBE_MAP,E);let me;if(De){V&&_e&&t.texStorage2D(i.TEXTURE_CUBE_MAP,ge,Ie,Re.width,Re.height);for(let se=0;se<6;se++){me=de[se].mipmaps;for(let Ee=0;Ee<me.length;Ee++){let Je=me[Ee];E.format!==He?ze!==null?V?J&&t.compressedTexSubImage2D(i.TEXTURE_CUBE_MAP_POSITIVE_X+se,Ee,0,0,Je.width,Je.height,ze,Je.data):t.compressedTexImage2D(i.TEXTURE_CUBE_MAP_POSITIVE_X+se,Ee,Ie,Je.width,Je.height,0,Je.data):Ze("WebGLRenderer: Attempt to load unsupported compressed texture format in .setTextureCube()"):V?J&&t.texSubImage2D(i.TEXTURE_CUBE_MAP_POSITIVE_X+se,Ee,0,0,Je.width,Je.height,ze,ve,Je.data):t.texImage2D(i.TEXTURE_CUBE_MAP_POSITIVE_X+se,Ee,Ie,Je.width,Je.height,0,ze,ve,Je.data)}}}else{if(me=E.mipmaps,V&&_e){me.length>0&&ge++;let se=$e(de[0]);t.texStorage2D(i.TEXTURE_CUBE_MAP,ge,Ie,se.width,se.height)}for(let se=0;se<6;se++)if(fe){V?J&&t.texSubImage2D(i.TEXTURE_CUBE_MAP_POSITIVE_X+se,0,0,0,de[se].width,de[se].height,ze,ve,de[se].data):t.texImage2D(i.TEXTURE_CUBE_MAP_POSITIVE_X+se,0,Ie,de[se].width,de[se].height,0,ze,ve,de[se].data);for(let Ee=0;Ee<me.length;Ee++){let At=me[Ee].image[se].image;V?J&&t.texSubImage2D(i.TEXTURE_CUBE_MAP_POSITIVE_X+se,Ee+1,0,0,At.width,At.height,ze,ve,At.data):t.texImage2D(i.TEXTURE_CUBE_MAP_POSITIVE_X+se,Ee+1,Ie,At.width,At.height,0,ze,ve,At.data)}}else{V?J&&t.texSubImage2D(i.TEXTURE_CUBE_MAP_POSITIVE_X+se,0,0,0,ze,ve,de[se]):t.texImage2D(i.TEXTURE_CUBE_MAP_POSITIVE_X+se,0,Ie,ze,ve,de[se]);for(let Ee=0;Ee<me.length;Ee++){let Je=me[Ee];V?J&&t.texSubImage2D(i.TEXTURE_CUBE_MAP_POSITIVE_X+se,Ee+1,0,0,ze,ve,Je.image[se]):t.texImage2D(i.TEXTURE_CUBE_MAP_POSITIVE_X+se,Ee+1,Ie,ze,ve,Je.image[se])}}}m(E)&&d(i.TEXTURE_CUBE_MAP),te.__version=ue.version,E.onUpdate&&E.onUpdate(E)}N.__version=E.version}function be(N,E,$,ie,ue,te){let Fe=s.convert($.format,$.colorSpace),xe=s.convert($.type),Oe=y($.internalFormat,Fe,xe,$.colorSpace),De=n.get(E),fe=n.get($);if(fe.__renderTarget=E,!De.__hasExternalTextures){let de=Math.max(1,E.width>>te),Re=Math.max(1,E.height>>te);ue===i.TEXTURE_3D||ue===i.TEXTURE_2D_ARRAY?t.texImage3D(ue,te,Oe,de,Re,E.depth,0,Fe,xe,null):t.texImage2D(ue,te,Oe,de,Re,0,Fe,xe,null)}t.bindFramebuffer(i.FRAMEBUFFER,N),Ae(E)?o.framebufferTexture2DMultisampleEXT(i.FRAMEBUFFER,ie,ue,fe.__webglTexture,0,yt(E)):(ue===i.TEXTURE_2D||ue>=i.TEXTURE_CUBE_MAP_POSITIVE_X&&ue<=i.TEXTURE_CUBE_MAP_NEGATIVE_Z)&&i.framebufferTexture2D(i.FRAMEBUFFER,ie,ue,fe.__webglTexture,te),t.bindFramebuffer(i.FRAMEBUFFER,null)}function We(N,E,$){if(i.bindRenderbuffer(i.RENDERBUFFER,N),E.depthBuffer){let ie=E.depthTexture,ue=ie&&ie.isDepthTexture?ie.type:null,te=M(E.stencilBuffer,ue),Fe=E.stencilBuffer?i.DEPTH_STENCIL_ATTACHMENT:i.DEPTH_ATTACHMENT,xe=yt(E);Ae(E)?o.renderbufferStorageMultisampleEXT(i.RENDERBUFFER,xe,te,E.width,E.height):$?i.renderbufferStorageMultisample(i.RENDERBUFFER,xe,te,E.width,E.height):i.renderbufferStorage(i.RENDERBUFFER,te,E.width,E.height),i.framebufferRenderbuffer(i.FRAMEBUFFER,Fe,i.RENDERBUFFER,N)}else{let ie=E.textures;for(let ue=0;ue<ie.length;ue++){let te=ie[ue],Fe=s.convert(te.format,te.colorSpace),xe=s.convert(te.type),Oe=y(te.internalFormat,Fe,xe,te.colorSpace),De=yt(E);$&&Ae(E)===!1?i.renderbufferStorageMultisample(i.RENDERBUFFER,De,Oe,E.width,E.height):Ae(E)?o.renderbufferStorageMultisampleEXT(i.RENDERBUFFER,De,Oe,E.width,E.height):i.renderbufferStorage(i.RENDERBUFFER,Oe,E.width,E.height)}}i.bindRenderbuffer(i.RENDERBUFFER,null)}function Pe(N,E){if(E&&E.isWebGLCubeRenderTarget)throw new Error("Depth Texture with cube render targets is not supported");if(t.bindFramebuffer(i.FRAMEBUFFER,N),!(E.depthTexture&&E.depthTexture.isDepthTexture))throw new Error("renderTarget.depthTexture must be an instance of THREE.DepthTexture");let ie=n.get(E.depthTexture);ie.__renderTarget=E,(!ie.__webglTexture||E.depthTexture.image.width!==E.width||E.depthTexture.image.height!==E.height)&&(E.depthTexture.image.width=E.width,E.depthTexture.image.height=E.height,E.depthTexture.needsUpdate=!0),q(E.depthTexture,0);let ue=ie.__webglTexture,te=yt(E);if(E.depthTexture.format===kr)Ae(E)?o.framebufferTexture2DMultisampleEXT(i.FRAMEBUFFER,i.DEPTH_ATTACHMENT,i.TEXTURE_2D,ue,0,te):i.framebufferTexture2D(i.FRAMEBUFFER,i.DEPTH_ATTACHMENT,i.TEXTURE_2D,ue,0);else if(E.depthTexture.format===Qr)Ae(E)?o.framebufferTexture2DMultisampleEXT(i.FRAMEBUFFER,i.DEPTH_STENCIL_ATTACHMENT,i.TEXTURE_2D,ue,0,te):i.framebufferTexture2D(i.FRAMEBUFFER,i.DEPTH_STENCIL_ATTACHMENT,i.TEXTURE_2D,ue,0);else throw new Error("Unknown depthTexture format")}function Qe(N){let E=n.get(N),$=N.isWebGLCubeRenderTarget===!0;if(E.__boundDepthTexture!==N.depthTexture){let ie=N.depthTexture;if(E.__depthDisposeCallback&&E.__depthDisposeCallback(),ie){let ue=()=>{delete E.__boundDepthTexture,delete E.__depthDisposeCallback,ie.removeEventListener("dispose",ue)};ie.addEventListener("dispose",ue),E.__depthDisposeCallback=ue}E.__boundDepthTexture=ie}if(N.depthTexture&&!E.__autoAllocateDepthBuffer){if($)throw new Error("target.depthTexture not supported in Cube render targets");let ie=N.texture.mipmaps;ie&&ie.length>0?Pe(E.__webglFramebuffer[0],N):Pe(E.__webglFramebuffer,N)}else if($){E.__webglDepthbuffer=[];for(let ie=0;ie<6;ie++)if(t.bindFramebuffer(i.FRAMEBUFFER,E.__webglFramebuffer[ie]),E.__webglDepthbuffer[ie]===void 0)E.__webglDepthbuffer[ie]=i.createRenderbuffer(),We(E.__webglDepthbuffer[ie],N,!1);else{let ue=N.stencilBuffer?i.DEPTH_STENCIL_ATTACHMENT:i.DEPTH_ATTACHMENT,te=E.__webglDepthbuffer[ie];i.bindRenderbuffer(i.RENDERBUFFER,te),i.framebufferRenderbuffer(i.FRAMEBUFFER,ue,i.RENDERBUFFER,te)}}else{let ie=N.texture.mipmaps;if(ie&&ie.length>0?t.bindFramebuffer(i.FRAMEBUFFER,E.__webglFramebuffer[0]):t.bindFramebuffer(i.FRAMEBUFFER,E.__webglFramebuffer),E.__webglDepthbuffer===void 0)E.__webglDepthbuffer=i.createRenderbuffer(),We(E.__webglDepthbuffer,N,!1);else{let ue=N.stencilBuffer?i.DEPTH_STENCIL_ATTACHMENT:i.DEPTH_ATTACHMENT,te=E.__webglDepthbuffer;i.bindRenderbuffer(i.RENDERBUFFER,te),i.framebufferRenderbuffer(i.FRAMEBUFFER,ue,i.RENDERBUFFER,te)}}t.bindFramebuffer(i.FRAMEBUFFER,null)}function Rt(N,E,$){let ie=n.get(N);E!==void 0&&be(ie.__webglFramebuffer,N,N.texture,i.COLOR_ATTACHMENT0,i.TEXTURE_2D,0),$!==void 0&&Qe(N)}function tt(N){let E=N.texture,$=n.get(N),ie=n.get(E);N.addEventListener("dispose",I);let ue=N.textures,te=N.isWebGLCubeRenderTarget===!0,Fe=ue.length>1;if(Fe||(ie.__webglTexture===void 0&&(ie.__webglTexture=i.createTexture()),ie.__version=E.version,a.memory.textures++),te){$.__webglFramebuffer=[];for(let xe=0;xe<6;xe++)if(E.mipmaps&&E.mipmaps.length>0){$.__webglFramebuffer[xe]=[];for(let Oe=0;Oe<E.mipmaps.length;Oe++)$.__webglFramebuffer[xe][Oe]=i.createFramebuffer()}else $.__webglFramebuffer[xe]=i.createFramebuffer()}else{if(E.mipmaps&&E.mipmaps.length>0){$.__webglFramebuffer=[];for(let xe=0;xe<E.mipmaps.length;xe++)$.__webglFramebuffer[xe]=i.createFramebuffer()}else $.__webglFramebuffer=i.createFramebuffer();if(Fe)for(let xe=0,Oe=ue.length;xe<Oe;xe++){let De=n.get(ue[xe]);De.__webglTexture===void 0&&(De.__webglTexture=i.createTexture(),a.memory.textures++)}if(N.samples>0&&Ae(N)===!1){$.__webglMultisampledFramebuffer=i.createFramebuffer(),$.__webglColorRenderbuffer=[],t.bindFramebuffer(i.FRAMEBUFFER,$.__webglMultisampledFramebuffer);for(let xe=0;xe<ue.length;xe++){let Oe=ue[xe];$.__webglColorRenderbuffer[xe]=i.createRenderbuffer(),i.bindRenderbuffer(i.RENDERBUFFER,$.__webglColorRenderbuffer[xe]);let De=s.convert(Oe.format,Oe.colorSpace),fe=s.convert(Oe.type),de=y(Oe.internalFormat,De,fe,Oe.colorSpace,N.isXRRenderTarget===!0),Re=yt(N);i.renderbufferStorageMultisample(i.RENDERBUFFER,Re,de,N.width,N.height),i.framebufferRenderbuffer(i.FRAMEBUFFER,i.COLOR_ATTACHMENT0+xe,i.RENDERBUFFER,$.__webglColorRenderbuffer[xe])}i.bindRenderbuffer(i.RENDERBUFFER,null),N.depthBuffer&&($.__webglDepthRenderbuffer=i.createRenderbuffer(),We($.__webglDepthRenderbuffer,N,!0)),t.bindFramebuffer(i.FRAMEBUFFER,null)}}if(te){t.bindTexture(i.TEXTURE_CUBE_MAP,ie.__webglTexture),Ce(i.TEXTURE_CUBE_MAP,E);for(let xe=0;xe<6;xe++)if(E.mipmaps&&E.mipmaps.length>0)for(let Oe=0;Oe<E.mipmaps.length;Oe++)be($.__webglFramebuffer[xe][Oe],N,E,i.COLOR_ATTACHMENT0,i.TEXTURE_CUBE_MAP_POSITIVE_X+xe,Oe);else be($.__webglFramebuffer[xe],N,E,i.COLOR_ATTACHMENT0,i.TEXTURE_CUBE_MAP_POSITIVE_X+xe,0);m(E)&&d(i.TEXTURE_CUBE_MAP),t.unbindTexture()}else if(Fe){for(let xe=0,Oe=ue.length;xe<Oe;xe++){let De=ue[xe],fe=n.get(De),de=i.TEXTURE_2D;(N.isWebGL3DRenderTarget||N.isWebGLArrayRenderTarget)&&(de=N.isWebGL3DRenderTarget?i.TEXTURE_3D:i.TEXTURE_2D_ARRAY),t.bindTexture(de,fe.__webglTexture),Ce(de,De),be($.__webglFramebuffer,N,De,i.COLOR_ATTACHMENT0+xe,de,0),m(De)&&d(de)}t.unbindTexture()}else{let xe=i.TEXTURE_2D;if((N.isWebGL3DRenderTarget||N.isWebGLArrayRenderTarget)&&(xe=N.isWebGL3DRenderTarget?i.TEXTURE_3D:i.TEXTURE_2D_ARRAY),t.bindTexture(xe,ie.__webglTexture),Ce(xe,E),E.mipmaps&&E.mipmaps.length>0)for(let Oe=0;Oe<E.mipmaps.length;Oe++)be($.__webglFramebuffer[Oe],N,E,i.COLOR_ATTACHMENT0,xe,Oe);else be($.__webglFramebuffer,N,E,i.COLOR_ATTACHMENT0,xe,0);m(E)&&d(xe),t.unbindTexture()}N.depthBuffer&&Qe(N)}function wt(N){let E=N.textures;for(let $=0,ie=E.length;$<ie;$++){let ue=E[$];if(m(ue)){let te=_(N),Fe=n.get(ue).__webglTexture;t.bindTexture(te,Fe),d(te),t.unbindTexture()}}}let G=[],at=[];function ot(N){if(N.samples>0){if(Ae(N)===!1){let E=N.textures,$=N.width,ie=N.height,ue=i.COLOR_BUFFER_BIT,te=N.stencilBuffer?i.DEPTH_STENCIL_ATTACHMENT:i.DEPTH_ATTACHMENT,Fe=n.get(N),xe=E.length>1;if(xe)for(let De=0;De<E.length;De++)t.bindFramebuffer(i.FRAMEBUFFER,Fe.__webglMultisampledFramebuffer),i.framebufferRenderbuffer(i.FRAMEBUFFER,i.COLOR_ATTACHMENT0+De,i.RENDERBUFFER,null),t.bindFramebuffer(i.FRAMEBUFFER,Fe.__webglFramebuffer),i.framebufferTexture2D(i.DRAW_FRAMEBUFFER,i.COLOR_ATTACHMENT0+De,i.TEXTURE_2D,null,0);t.bindFramebuffer(i.READ_FRAMEBUFFER,Fe.__webglMultisampledFramebuffer);let Oe=N.texture.mipmaps;Oe&&Oe.length>0?t.bindFramebuffer(i.DRAW_FRAMEBUFFER,Fe.__webglFramebuffer[0]):t.bindFramebuffer(i.DRAW_FRAMEBUFFER,Fe.__webglFramebuffer);for(let De=0;De<E.length;De++){if(N.resolveDepthBuffer&&(N.depthBuffer&&(ue|=i.DEPTH_BUFFER_BIT),N.stencilBuffer&&N.resolveStencilBuffer&&(ue|=i.STENCIL_BUFFER_BIT)),xe){i.framebufferRenderbuffer(i.READ_FRAMEBUFFER,i.COLOR_ATTACHMENT0,i.RENDERBUFFER,Fe.__webglColorRenderbuffer[De]);let fe=n.get(E[De]).__webglTexture;i.framebufferTexture2D(i.DRAW_FRAMEBUFFER,i.COLOR_ATTACHMENT0,i.TEXTURE_2D,fe,0)}i.blitFramebuffer(0,0,$,ie,0,0,$,ie,ue,i.NEAREST),c===!0&&(G.length=0,at.length=0,G.push(i.COLOR_ATTACHMENT0+De),N.depthBuffer&&N.resolveDepthBuffer===!1&&(G.push(te),at.push(te),i.invalidateFramebuffer(i.DRAW_FRAMEBUFFER,at)),i.invalidateFramebuffer(i.READ_FRAMEBUFFER,G))}if(t.bindFramebuffer(i.READ_FRAMEBUFFER,null),t.bindFramebuffer(i.DRAW_FRAMEBUFFER,null),xe)for(let De=0;De<E.length;De++){t.bindFramebuffer(i.FRAMEBUFFER,Fe.__webglMultisampledFramebuffer),i.framebufferRenderbuffer(i.FRAMEBUFFER,i.COLOR_ATTACHMENT0+De,i.RENDERBUFFER,Fe.__webglColorRenderbuffer[De]);let fe=n.get(E[De]).__webglTexture;t.bindFramebuffer(i.FRAMEBUFFER,Fe.__webglFramebuffer),i.framebufferTexture2D(i.DRAW_FRAMEBUFFER,i.COLOR_ATTACHMENT0+De,i.TEXTURE_2D,fe,0)}t.bindFramebuffer(i.DRAW_FRAMEBUFFER,Fe.__webglMultisampledFramebuffer)}else if(N.depthBuffer&&N.resolveDepthBuffer===!1&&c){let E=N.stencilBuffer?i.DEPTH_STENCIL_ATTACHMENT:i.DEPTH_ATTACHMENT;i.invalidateFramebuffer(i.DRAW_FRAMEBUFFER,[E])}}}function yt(N){return Math.min(r.maxSamples,N.samples)}function Ae(N){let E=n.get(N);return N.samples>0&&e.has("WEBGL_multisampled_render_to_texture")===!0&&E.__useRenderToTexture!==!1}function It(N){let E=a.render.frame;f.get(N)!==E&&(f.set(N,E),N.update())}function Be(N,E){let $=N.colorSpace,ie=N.format,ue=N.type;return N.isCompressedTexture===!0||N.isVideoTexture===!0||$!==Gt&&$!==gi&&(dt.getTransfer($)===bt?(ie!==He||ue!==dn)&&Ze("WebGLTextures: sRGB encoded textures have to use RGBAFormat and UnsignedByteType."):ut("WebGLTextures: Unsupported texture color space:",$)),E}function $e(N){return typeof HTMLImageElement<"u"&&N instanceof HTMLImageElement?(u.width=N.naturalWidth||N.width,u.height=N.naturalHeight||N.height):typeof VideoFrame<"u"&&N instanceof VideoFrame?(u.width=N.displayWidth,u.height=N.displayHeight):(u.width=N.width,u.height=N.height),u}this.allocateTextureUnit=O,this.resetTextureUnits=L,this.setTexture2D=q,this.setTexture2DArray=Y,this.setTexture3D=he,this.setTextureCube=j,this.rebindTextures=Rt,this.setupRenderTarget=tt,this.updateRenderTargetMipmap=wt,this.updateMultisampleRenderTarget=ot,this.setupDepthRenderbuffer=Qe,this.setupFrameBufferTexture=be,this.useMultisampledRTT=Ae}function D_(i,e){function t(n,r=gi){let s,a=dt.getTransfer(r);if(n===dn)return i.UNSIGNED_BYTE;if(n===Uo)return i.UNSIGNED_SHORT_4_4_4_4;if(n===Bo)return i.UNSIGNED_SHORT_5_5_5_1;if(n===Mu)return i.UNSIGNED_INT_5_9_9_9_REV;if(n===Tu)return i.UNSIGNED_INT_10F_11F_11F_REV;if(n===Jr)return i.BYTE;if(n===ra)return i.SHORT;if(n===Li)return i.UNSIGNED_SHORT;if(n===Ni)return i.INT;if(n===xn)return i.UNSIGNED_INT;if(n===qe)return i.FLOAT;if(n===_t)return i.HALF_FLOAT;if(n===wu)return i.ALPHA;if(n===Au)return i.RGB;if(n===He)return i.RGBA;if(n===kr)return i.DEPTH_COMPONENT;if(n===Qr)return i.DEPTH_STENCIL;if(n===vn)return i.RED;if(n===jr)return i.RED_INTEGER;if(n===Tn)return i.RG;if(n===Ui)return i.RG_INTEGER;if(n===Bi)return i.RGBA_INTEGER;if(n===sa||n===aa||n===oa||n===ca)if(a===bt)if(s=e.get("WEBGL_compressed_texture_s3tc_srgb"),s!==null){if(n===sa)return s.COMPRESSED_SRGB_S3TC_DXT1_EXT;if(n===aa)return s.COMPRESSED_SRGB_ALPHA_S3TC_DXT1_EXT;if(n===oa)return s.COMPRESSED_SRGB_ALPHA_S3TC_DXT3_EXT;if(n===ca)return s.COMPRESSED_SRGB_ALPHA_S3TC_DXT5_EXT}else return null;else if(s=e.get("WEBGL_compressed_texture_s3tc"),s!==null){if(n===sa)return s.COMPRESSED_RGB_S3TC_DXT1_EXT;if(n===aa)return s.COMPRESSED_RGBA_S3TC_DXT1_EXT;if(n===oa)return s.COMPRESSED_RGBA_S3TC_DXT3_EXT;if(n===ca)return s.COMPRESSED_RGBA_S3TC_DXT5_EXT}else return null;if(n===Oo||n===zo||n===ko||n===Vo)if(s=e.get("WEBGL_compressed_texture_pvrtc"),s!==null){if(n===Oo)return s.COMPRESSED_RGB_PVRTC_4BPPV1_IMG;if(n===zo)return s.COMPRESSED_RGB_PVRTC_2BPPV1_IMG;if(n===ko)return s.COMPRESSED_RGBA_PVRTC_4BPPV1_IMG;if(n===Vo)return s.COMPRESSED_RGBA_PVRTC_2BPPV1_IMG}else return null;if(n===Ho||n===Go||n===Wo)if(s=e.get("WEBGL_compressed_texture_etc"),s!==null){if(n===Ho||n===Go)return a===bt?s.COMPRESSED_SRGB8_ETC2:s.COMPRESSED_RGB8_ETC2;if(n===Wo)return a===bt?s.COMPRESSED_SRGB8_ALPHA8_ETC2_EAC:s.COMPRESSED_RGBA8_ETC2_EAC}else return null;if(n===Xo||n===qo||n===Yo||n===Zo||n===$o||n===Jo||n===Ko||n===Qo||n===jo||n===ec||n===tc||n===nc||n===ic||n===rc)if(s=e.get("WEBGL_compressed_texture_astc"),s!==null){if(n===Xo)return a===bt?s.COMPRESSED_SRGB8_ALPHA8_ASTC_4x4_KHR:s.COMPRESSED_RGBA_ASTC_4x4_KHR;if(n===qo)return a===bt?s.COMPRESSED_SRGB8_ALPHA8_ASTC_5x4_KHR:s.COMPRESSED_RGBA_ASTC_5x4_KHR;if(n===Yo)return a===bt?s.COMPRESSED_SRGB8_ALPHA8_ASTC_5x5_KHR:s.COMPRESSED_RGBA_ASTC_5x5_KHR;if(n===Zo)return a===bt?s.COMPRESSED_SRGB8_ALPHA8_ASTC_6x5_KHR:s.COMPRESSED_RGBA_ASTC_6x5_KHR;if(n===$o)return a===bt?s.COMPRESSED_SRGB8_ALPHA8_ASTC_6x6_KHR:s.COMPRESSED_RGBA_ASTC_6x6_KHR;if(n===Jo)return a===bt?s.COMPRESSED_SRGB8_ALPHA8_ASTC_8x5_KHR:s.COMPRESSED_RGBA_ASTC_8x5_KHR;if(n===Ko)return a===bt?s.COMPRESSED_SRGB8_ALPHA8_ASTC_8x6_KHR:s.COMPRESSED_RGBA_ASTC_8x6_KHR;if(n===Qo)return a===bt?s.COMPRESSED_SRGB8_ALPHA8_ASTC_8x8_KHR:s.COMPRESSED_RGBA_ASTC_8x8_KHR;if(n===jo)return a===bt?s.COMPRESSED_SRGB8_ALPHA8_ASTC_10x5_KHR:s.COMPRESSED_RGBA_ASTC_10x5_KHR;if(n===ec)return a===bt?s.COMPRESSED_SRGB8_ALPHA8_ASTC_10x6_KHR:s.COMPRESSED_RGBA_ASTC_10x6_KHR;if(n===tc)return a===bt?s.COMPRESSED_SRGB8_ALPHA8_ASTC_10x8_KHR:s.COMPRESSED_RGBA_ASTC_10x8_KHR;if(n===nc)return a===bt?s.COMPRESSED_SRGB8_ALPHA8_ASTC_10x10_KHR:s.COMPRESSED_RGBA_ASTC_10x10_KHR;if(n===ic)return a===bt?s.COMPRESSED_SRGB8_ALPHA8_ASTC_12x10_KHR:s.COMPRESSED_RGBA_ASTC_12x10_KHR;if(n===rc)return a===bt?s.COMPRESSED_SRGB8_ALPHA8_ASTC_12x12_KHR:s.COMPRESSED_RGBA_ASTC_12x12_KHR}else return null;if(n===sc||n===ac||n===oc)if(s=e.get("EXT_texture_compression_bptc"),s!==null){if(n===sc)return a===bt?s.COMPRESSED_SRGB_ALPHA_BPTC_UNORM_EXT:s.COMPRESSED_RGBA_BPTC_UNORM_EXT;if(n===ac)return s.COMPRESSED_RGB_BPTC_SIGNED_FLOAT_EXT;if(n===oc)return s.COMPRESSED_RGB_BPTC_UNSIGNED_FLOAT_EXT}else return null;if(n===cc||n===lc||n===uc||n===hc)if(s=e.get("EXT_texture_compression_rgtc"),s!==null){if(n===cc)return s.COMPRESSED_RED_RGTC1_EXT;if(n===lc)return s.COMPRESSED_SIGNED_RED_RGTC1_EXT;if(n===uc)return s.COMPRESSED_RED_GREEN_RGTC2_EXT;if(n===hc)return s.COMPRESSED_SIGNED_RED_GREEN_RGTC2_EXT}else return null;return n===Kr?i.UNSIGNED_INT_24_8:i[n]!==void 0?i[n]:null}return{convert:t}}var F_=`
void main() {

	gl_Position = vec4( position, 1.0 );

}`,L_=`
uniform sampler2DArray depthColor;
uniform float depthWidth;
uniform float depthHeight;

void main() {

	vec2 coord = vec2( gl_FragCoord.x / depthWidth, gl_FragCoord.y / depthHeight );

	if ( coord.x >= 1.0 ) {

		gl_FragDepth = texture( depthColor, vec3( coord.x - 1.0, coord.y, 1 ) ).r;

	} else {

		gl_FragDepth = texture( depthColor, vec3( coord.x, coord.y, 0 ) ).r;

	}

}`,Yu=class{constructor(){this.texture=null,this.mesh=null,this.depthNear=0,this.depthFar=0}init(e,t){if(this.texture===null){let n=new Ws(e.texture);(e.depthNear!==t.depthNear||e.depthFar!==t.depthFar)&&(this.depthNear=e.depthNear,this.depthFar=e.depthFar),this.texture=n}}getMesh(e){if(this.texture!==null&&this.mesh===null){let t=e.cameras[0].viewport,n=new Xt({vertexShader:F_,fragmentShader:L_,uniforms:{depthColor:{value:this.texture},depthWidth:{value:t.z},depthHeight:{value:t.w}}});this.mesh=new rn(new Xs(20,20),n)}return this.mesh}reset(){this.texture=null,this.mesh=null}getDepthTexture(){return this.texture}},Zu=class extends di{constructor(e,t){super();let n=this,r=null,s=1,a=null,o="local-floor",c=1,u=null,f=null,h=null,l=null,p=null,g=null,b=typeof XRWebGLBinding<"u",m=new Yu,d={},_=t.getContextAttributes(),y=null,M=null,w=[],A=[],I=new Le,D=null,T=new kt;T.viewport=new ht;let S=new kt;S.viewport=new ht;let P=[T,S],L=new wo,O=null,H=null;this.cameraAutoUpdate=!0,this.enabled=!1,this.isPresenting=!1,this.getController=function(K){let re=w[K];return re===void 0&&(re=new Yr,w[K]=re),re.getTargetRaySpace()},this.getControllerGrip=function(K){let re=w[K];return re===void 0&&(re=new Yr,w[K]=re),re.getGripSpace()},this.getHand=function(K){let re=w[K];return re===void 0&&(re=new Yr,w[K]=re),re.getHandSpace()};function q(K){let re=A.indexOf(K.inputSource);if(re===-1)return;let be=w[re];be!==void 0&&(be.update(K.inputSource,K.frame,u||a),be.dispatchEvent({type:K.type,data:K.inputSource}))}function Y(){r.removeEventListener("select",q),r.removeEventListener("selectstart",q),r.removeEventListener("selectend",q),r.removeEventListener("squeeze",q),r.removeEventListener("squeezestart",q),r.removeEventListener("squeezeend",q),r.removeEventListener("end",Y),r.removeEventListener("inputsourceschange",he);for(let K=0;K<w.length;K++){let re=A[K];re!==null&&(A[K]=null,w[K].disconnect(re))}O=null,H=null,m.reset();for(let K in d)delete d[K];e.setRenderTarget(y),p=null,l=null,h=null,r=null,M=null,nt.stop(),n.isPresenting=!1,e.setPixelRatio(D),e.setSize(I.width,I.height,!1),n.dispatchEvent({type:"sessionend"})}this.setFramebufferScaleFactor=function(K){s=K,n.isPresenting===!0&&Ze("WebXRManager: Cannot change framebuffer scale while presenting.")},this.setReferenceSpaceType=function(K){o=K,n.isPresenting===!0&&Ze("WebXRManager: Cannot change reference space type while presenting.")},this.getReferenceSpace=function(){return u||a},this.setReferenceSpace=function(K){u=K},this.getBaseLayer=function(){return l!==null?l:p},this.getBinding=function(){return h===null&&b&&(h=new XRWebGLBinding(r,t)),h},this.getFrame=function(){return g},this.getSession=function(){return r},this.setSession=async function(K){if(r=K,r!==null){if(y=e.getRenderTarget(),r.addEventListener("select",q),r.addEventListener("selectstart",q),r.addEventListener("selectend",q),r.addEventListener("squeeze",q),r.addEventListener("squeezestart",q),r.addEventListener("squeezeend",q),r.addEventListener("end",Y),r.addEventListener("inputsourceschange",he),_.xrCompatible!==!0&&await t.makeXRCompatible(),D=e.getPixelRatio(),e.getSize(I),b&&"createProjectionLayer"in XRWebGLBinding.prototype){let be=null,We=null,Pe=null;_.depth&&(Pe=_.stencil?t.DEPTH24_STENCIL8:t.DEPTH_COMPONENT24,be=_.stencil?Qr:kr,We=_.stencil?Kr:xn);let Qe={colorFormat:t.RGBA8,depthFormat:Pe,scaleFactor:s};h=this.getBinding(),l=h.createProjectionLayer(Qe),r.updateRenderState({layers:[l]}),e.setPixelRatio(1),e.setSize(l.textureWidth,l.textureHeight,!1),M=new Yt(l.textureWidth,l.textureHeight,{format:He,type:dn,depthTexture:new Gs(l.textureWidth,l.textureHeight,We,void 0,void 0,void 0,void 0,void 0,void 0,be),stencilBuffer:_.stencil,colorSpace:e.outputColorSpace,samples:_.antialias?4:0,resolveDepthBuffer:l.ignoreDepthValues===!1,resolveStencilBuffer:l.ignoreDepthValues===!1})}else{let be={antialias:_.antialias,alpha:!0,depth:_.depth,stencil:_.stencil,framebufferScaleFactor:s};p=new XRWebGLLayer(r,t,be),r.updateRenderState({baseLayer:p}),e.setPixelRatio(1),e.setSize(p.framebufferWidth,p.framebufferHeight,!1),M=new Yt(p.framebufferWidth,p.framebufferHeight,{format:He,type:dn,colorSpace:e.outputColorSpace,stencilBuffer:_.stencil,resolveDepthBuffer:p.ignoreDepthValues===!1,resolveStencilBuffer:p.ignoreDepthValues===!1})}M.isXRRenderTarget=!0,this.setFoveation(c),u=null,a=await r.requestReferenceSpace(o),nt.setContext(r),nt.start(),n.isPresenting=!0,n.dispatchEvent({type:"sessionstart"})}},this.getEnvironmentBlendMode=function(){if(r!==null)return r.environmentBlendMode},this.getDepthTexture=function(){return m.getDepthTexture()};function he(K){for(let re=0;re<K.removed.length;re++){let be=K.removed[re],We=A.indexOf(be);We>=0&&(A[We]=null,w[We].disconnect(be))}for(let re=0;re<K.added.length;re++){let be=K.added[re],We=A.indexOf(be);if(We===-1){for(let Qe=0;Qe<w.length;Qe++)if(Qe>=A.length){A.push(be),We=Qe;break}else if(A[Qe]===null){A[Qe]=be,We=Qe;break}if(We===-1)break}let Pe=w[We];Pe&&Pe.connect(be)}}let j=new k,le=new k;function ce(K,re,be){j.setFromMatrixPosition(re.matrixWorld),le.setFromMatrixPosition(be.matrixWorld);let We=j.distanceTo(le),Pe=re.projectionMatrix.elements,Qe=be.projectionMatrix.elements,Rt=Pe[14]/(Pe[10]-1),tt=Pe[14]/(Pe[10]+1),wt=(Pe[9]+1)/Pe[5],G=(Pe[9]-1)/Pe[5],at=(Pe[8]-1)/Pe[0],ot=(Qe[8]+1)/Qe[0],yt=Rt*at,Ae=Rt*ot,It=We/(-at+ot),Be=It*-at;if(re.matrixWorld.decompose(K.position,K.quaternion,K.scale),K.translateX(Be),K.translateZ(It),K.matrixWorld.compose(K.position,K.quaternion,K.scale),K.matrixWorldInverse.copy(K.matrixWorld).invert(),Pe[10]===-1)K.projectionMatrix.copy(re.projectionMatrix),K.projectionMatrixInverse.copy(re.projectionMatrixInverse);else{let $e=Rt+It,N=tt+It,E=yt-Be,$=Ae+(We-Be),ie=wt*tt/N*$e,ue=G*tt/N*$e;K.projectionMatrix.makePerspective(E,$,ie,ue,$e,N),K.projectionMatrixInverse.copy(K.projectionMatrix).invert()}}function we(K,re){re===null?K.matrixWorld.copy(K.matrix):K.matrixWorld.multiplyMatrices(re.matrixWorld,K.matrix),K.matrixWorldInverse.copy(K.matrixWorld).invert()}this.updateCamera=function(K){if(r===null)return;let re=K.near,be=K.far;m.texture!==null&&(m.depthNear>0&&(re=m.depthNear),m.depthFar>0&&(be=m.depthFar)),L.near=S.near=T.near=re,L.far=S.far=T.far=be,(O!==L.near||H!==L.far)&&(r.updateRenderState({depthNear:L.near,depthFar:L.far}),O=L.near,H=L.far),L.layers.mask=K.layers.mask|6,T.layers.mask=L.layers.mask&3,S.layers.mask=L.layers.mask&5;let We=K.parent,Pe=L.cameras;we(L,We);for(let Qe=0;Qe<Pe.length;Qe++)we(Pe[Qe],We);Pe.length===2?ce(L,T,S):L.projectionMatrix.copy(T.projectionMatrix),Ce(K,L,We)};function Ce(K,re,be){be===null?K.matrix.copy(re.matrixWorld):(K.matrix.copy(be.matrixWorld),K.matrix.invert(),K.matrix.multiply(re.matrixWorld)),K.matrix.decompose(K.position,K.quaternion,K.scale),K.updateMatrixWorld(!0),K.projectionMatrix.copy(re.projectionMatrix),K.projectionMatrixInverse.copy(re.projectionMatrixInverse),K.isPerspectiveCamera&&(K.fov=Bs*2*Math.atan(1/K.projectionMatrix.elements[5]),K.zoom=1)}this.getCamera=function(){return L},this.getFoveation=function(){if(!(l===null&&p===null))return c},this.setFoveation=function(K){c=K,l!==null&&(l.fixedFoveation=K),p!==null&&p.fixedFoveation!==void 0&&(p.fixedFoveation=K)},this.hasDepthSensing=function(){return m.texture!==null},this.getDepthSensingMesh=function(){return m.getMesh(L)},this.getCameraTexture=function(K){return d[K]};let ke=null;function ct(K,re){if(f=re.getViewerPose(u||a),g=re,f!==null){let be=f.views;p!==null&&(e.setRenderTargetFramebuffer(M,p.framebuffer),e.setRenderTarget(M));let We=!1;be.length!==L.cameras.length&&(L.cameras.length=0,We=!0);for(let tt=0;tt<be.length;tt++){let wt=be[tt],G=null;if(p!==null)G=p.getViewport(wt);else{let ot=h.getViewSubImage(l,wt);G=ot.viewport,tt===0&&(e.setRenderTargetTextures(M,ot.colorTexture,ot.depthStencilTexture),e.setRenderTarget(M))}let at=P[tt];at===void 0&&(at=new kt,at.layers.enable(tt),at.viewport=new ht,P[tt]=at),at.matrix.fromArray(wt.transform.matrix),at.matrix.decompose(at.position,at.quaternion,at.scale),at.projectionMatrix.fromArray(wt.projectionMatrix),at.projectionMatrixInverse.copy(at.projectionMatrix).invert(),at.viewport.set(G.x,G.y,G.width,G.height),tt===0&&(L.matrix.copy(at.matrix),L.matrix.decompose(L.position,L.quaternion,L.scale)),We===!0&&L.cameras.push(at)}let Pe=r.enabledFeatures;if(Pe&&Pe.includes("depth-sensing")&&r.depthUsage=="gpu-optimized"&&b){h=n.getBinding();let tt=h.getDepthInformation(be[0]);tt&&tt.isValid&&tt.texture&&m.init(tt,r.renderState)}if(Pe&&Pe.includes("camera-access")&&b){e.state.unbindTexture(),h=n.getBinding();for(let tt=0;tt<be.length;tt++){let wt=be[tt].camera;if(wt){let G=d[wt];G||(G=new Ws,d[wt]=G);let at=h.getCameraImage(wt);G.sourceTexture=at}}}}for(let be=0;be<w.length;be++){let We=A[be],Pe=w[be];We!==null&&Pe!==void 0&&Pe.update(We,re,u||a)}ke&&ke(K,re),re.detectedPlanes&&n.dispatchEvent({type:"planesdetected",data:re}),g=null}let nt=new vd;nt.setAnimationLoop(ct),this.setAnimationLoop=function(K){ke=K},this.dispose=function(){}}},ur=new Xn,N_=new Xe;function U_(i,e){function t(m,d){m.matrixAutoUpdate===!0&&m.updateMatrix(),d.value.copy(m.matrix)}function n(m,d){d.color.getRGB(m.fogColor.value,Du(i)),d.isFog?(m.fogNear.value=d.near,m.fogFar.value=d.far):d.isFogExp2&&(m.fogDensity.value=d.density)}function r(m,d,_,y,M){d.isMeshBasicMaterial||d.isMeshLambertMaterial?s(m,d):d.isMeshToonMaterial?(s(m,d),h(m,d)):d.isMeshPhongMaterial?(s(m,d),f(m,d)):d.isMeshStandardMaterial?(s(m,d),l(m,d),d.isMeshPhysicalMaterial&&p(m,d,M)):d.isMeshMatcapMaterial?(s(m,d),g(m,d)):d.isMeshDepthMaterial?s(m,d):d.isMeshDistanceMaterial?(s(m,d),b(m,d)):d.isMeshNormalMaterial?s(m,d):d.isLineBasicMaterial?(a(m,d),d.isLineDashedMaterial&&o(m,d)):d.isPointsMaterial?c(m,d,_,y):d.isSpriteMaterial?u(m,d):d.isShadowMaterial?(m.color.value.copy(d.color),m.opacity.value=d.opacity):d.isShaderMaterial&&(d.uniformsNeedUpdate=!1)}function s(m,d){m.opacity.value=d.opacity,d.color&&m.diffuse.value.copy(d.color),d.emissive&&m.emissive.value.copy(d.emissive).multiplyScalar(d.emissiveIntensity),d.map&&(m.map.value=d.map,t(d.map,m.mapTransform)),d.alphaMap&&(m.alphaMap.value=d.alphaMap,t(d.alphaMap,m.alphaMapTransform)),d.bumpMap&&(m.bumpMap.value=d.bumpMap,t(d.bumpMap,m.bumpMapTransform),m.bumpScale.value=d.bumpScale,d.side===Zt&&(m.bumpScale.value*=-1)),d.normalMap&&(m.normalMap.value=d.normalMap,t(d.normalMap,m.normalMapTransform),m.normalScale.value.copy(d.normalScale),d.side===Zt&&m.normalScale.value.negate()),d.displacementMap&&(m.displacementMap.value=d.displacementMap,t(d.displacementMap,m.displacementMapTransform),m.displacementScale.value=d.displacementScale,m.displacementBias.value=d.displacementBias),d.emissiveMap&&(m.emissiveMap.value=d.emissiveMap,t(d.emissiveMap,m.emissiveMapTransform)),d.specularMap&&(m.specularMap.value=d.specularMap,t(d.specularMap,m.specularMapTransform)),d.alphaTest>0&&(m.alphaTest.value=d.alphaTest);let _=e.get(d),y=_.envMap,M=_.envMapRotation;y&&(m.envMap.value=y,ur.copy(M),ur.x*=-1,ur.y*=-1,ur.z*=-1,y.isCubeTexture&&y.isRenderTargetTexture===!1&&(ur.y*=-1,ur.z*=-1),m.envMapRotation.value.setFromMatrix4(N_.makeRotationFromEuler(ur)),m.flipEnvMap.value=y.isCubeTexture&&y.isRenderTargetTexture===!1?-1:1,m.reflectivity.value=d.reflectivity,m.ior.value=d.ior,m.refractionRatio.value=d.refractionRatio),d.lightMap&&(m.lightMap.value=d.lightMap,m.lightMapIntensity.value=d.lightMapIntensity,t(d.lightMap,m.lightMapTransform)),d.aoMap&&(m.aoMap.value=d.aoMap,m.aoMapIntensity.value=d.aoMapIntensity,t(d.aoMap,m.aoMapTransform))}function a(m,d){m.diffuse.value.copy(d.color),m.opacity.value=d.opacity,d.map&&(m.map.value=d.map,t(d.map,m.mapTransform))}function o(m,d){m.dashSize.value=d.dashSize,m.totalSize.value=d.dashSize+d.gapSize,m.scale.value=d.scale}function c(m,d,_,y){m.diffuse.value.copy(d.color),m.opacity.value=d.opacity,m.size.value=d.size*_,m.scale.value=y*.5,d.map&&(m.map.value=d.map,t(d.map,m.uvTransform)),d.alphaMap&&(m.alphaMap.value=d.alphaMap,t(d.alphaMap,m.alphaMapTransform)),d.alphaTest>0&&(m.alphaTest.value=d.alphaTest)}function u(m,d){m.diffuse.value.copy(d.color),m.opacity.value=d.opacity,m.rotation.value=d.rotation,d.map&&(m.map.value=d.map,t(d.map,m.mapTransform)),d.alphaMap&&(m.alphaMap.value=d.alphaMap,t(d.alphaMap,m.alphaMapTransform)),d.alphaTest>0&&(m.alphaTest.value=d.alphaTest)}function f(m,d){m.specular.value.copy(d.specular),m.shininess.value=Math.max(d.shininess,1e-4)}function h(m,d){d.gradientMap&&(m.gradientMap.value=d.gradientMap)}function l(m,d){m.metalness.value=d.metalness,d.metalnessMap&&(m.metalnessMap.value=d.metalnessMap,t(d.metalnessMap,m.metalnessMapTransform)),m.roughness.value=d.roughness,d.roughnessMap&&(m.roughnessMap.value=d.roughnessMap,t(d.roughnessMap,m.roughnessMapTransform)),d.envMap&&(m.envMapIntensity.value=d.envMapIntensity)}function p(m,d,_){m.ior.value=d.ior,d.sheen>0&&(m.sheenColor.value.copy(d.sheenColor).multiplyScalar(d.sheen),m.sheenRoughness.value=d.sheenRoughness,d.sheenColorMap&&(m.sheenColorMap.value=d.sheenColorMap,t(d.sheenColorMap,m.sheenColorMapTransform)),d.sheenRoughnessMap&&(m.sheenRoughnessMap.value=d.sheenRoughnessMap,t(d.sheenRoughnessMap,m.sheenRoughnessMapTransform))),d.clearcoat>0&&(m.clearcoat.value=d.clearcoat,m.clearcoatRoughness.value=d.clearcoatRoughness,d.clearcoatMap&&(m.clearcoatMap.value=d.clearcoatMap,t(d.clearcoatMap,m.clearcoatMapTransform)),d.clearcoatRoughnessMap&&(m.clearcoatRoughnessMap.value=d.clearcoatRoughnessMap,t(d.clearcoatRoughnessMap,m.clearcoatRoughnessMapTransform)),d.clearcoatNormalMap&&(m.clearcoatNormalMap.value=d.clearcoatNormalMap,t(d.clearcoatNormalMap,m.clearcoatNormalMapTransform),m.clearcoatNormalScale.value.copy(d.clearcoatNormalScale),d.side===Zt&&m.clearcoatNormalScale.value.negate())),d.dispersion>0&&(m.dispersion.value=d.dispersion),d.iridescence>0&&(m.iridescence.value=d.iridescence,m.iridescenceIOR.value=d.iridescenceIOR,m.iridescenceThicknessMinimum.value=d.iridescenceThicknessRange[0],m.iridescenceThicknessMaximum.value=d.iridescenceThicknessRange[1],d.iridescenceMap&&(m.iridescenceMap.value=d.iridescenceMap,t(d.iridescenceMap,m.iridescenceMapTransform)),d.iridescenceThicknessMap&&(m.iridescenceThicknessMap.value=d.iridescenceThicknessMap,t(d.iridescenceThicknessMap,m.iridescenceThicknessMapTransform))),d.transmission>0&&(m.transmission.value=d.transmission,m.transmissionSamplerMap.value=_.texture,m.transmissionSamplerSize.value.set(_.width,_.height),d.transmissionMap&&(m.transmissionMap.value=d.transmissionMap,t(d.transmissionMap,m.transmissionMapTransform)),m.thickness.value=d.thickness,d.thicknessMap&&(m.thicknessMap.value=d.thicknessMap,t(d.thicknessMap,m.thicknessMapTransform)),m.attenuationDistance.value=d.attenuationDistance,m.attenuationColor.value.copy(d.attenuationColor)),d.anisotropy>0&&(m.anisotropyVector.value.set(d.anisotropy*Math.cos(d.anisotropyRotation),d.anisotropy*Math.sin(d.anisotropyRotation)),d.anisotropyMap&&(m.anisotropyMap.value=d.anisotropyMap,t(d.anisotropyMap,m.anisotropyMapTransform))),m.specularIntensity.value=d.specularIntensity,m.specularColor.value.copy(d.specularColor),d.specularColorMap&&(m.specularColorMap.value=d.specularColorMap,t(d.specularColorMap,m.specularColorMapTransform)),d.specularIntensityMap&&(m.specularIntensityMap.value=d.specularIntensityMap,t(d.specularIntensityMap,m.specularIntensityMapTransform))}function g(m,d){d.matcap&&(m.matcap.value=d.matcap)}function b(m,d){let _=e.get(d).light;m.referencePosition.value.setFromMatrixPosition(_.matrixWorld),m.nearDistance.value=_.shadow.camera.near,m.farDistance.value=_.shadow.camera.far}return{refreshFogUniforms:n,refreshMaterialUniforms:r}}function B_(i,e,t,n){let r={},s={},a=[],o=i.getParameter(i.MAX_UNIFORM_BUFFER_BINDINGS);function c(_,y){let M=y.program;n.uniformBlockBinding(_,M)}function u(_,y){let M=r[_.id];M===void 0&&(g(_),M=f(_),r[_.id]=M,_.addEventListener("dispose",m));let w=y.program;n.updateUBOMapping(_,w);let A=e.render.frame;s[_.id]!==A&&(l(_),s[_.id]=A)}function f(_){let y=h();_.__bindingPointIndex=y;let M=i.createBuffer(),w=_.__size,A=_.usage;return i.bindBuffer(i.UNIFORM_BUFFER,M),i.bufferData(i.UNIFORM_BUFFER,w,A),i.bindBuffer(i.UNIFORM_BUFFER,null),i.bindBufferBase(i.UNIFORM_BUFFER,y,M),M}function h(){for(let _=0;_<o;_++)if(a.indexOf(_)===-1)return a.push(_),_;return ut("WebGLRenderer: Maximum number of simultaneously usable uniforms groups reached."),0}function l(_){let y=r[_.id],M=_.uniforms,w=_.__cache;i.bindBuffer(i.UNIFORM_BUFFER,y);for(let A=0,I=M.length;A<I;A++){let D=Array.isArray(M[A])?M[A]:[M[A]];for(let T=0,S=D.length;T<S;T++){let P=D[T];if(p(P,A,T,w)===!0){let L=P.__offset,O=Array.isArray(P.value)?P.value:[P.value],H=0;for(let q=0;q<O.length;q++){let Y=O[q],he=b(Y);typeof Y=="number"||typeof Y=="boolean"?(P.__data[0]=Y,i.bufferSubData(i.UNIFORM_BUFFER,L+H,P.__data)):Y.isMatrix3?(P.__data[0]=Y.elements[0],P.__data[1]=Y.elements[1],P.__data[2]=Y.elements[2],P.__data[3]=0,P.__data[4]=Y.elements[3],P.__data[5]=Y.elements[4],P.__data[6]=Y.elements[5],P.__data[7]=0,P.__data[8]=Y.elements[6],P.__data[9]=Y.elements[7],P.__data[10]=Y.elements[8],P.__data[11]=0):(Y.toArray(P.__data,H),H+=he.storage/Float32Array.BYTES_PER_ELEMENT)}i.bufferSubData(i.UNIFORM_BUFFER,L,P.__data)}}}i.bindBuffer(i.UNIFORM_BUFFER,null)}function p(_,y,M,w){let A=_.value,I=y+"_"+M;if(w[I]===void 0)return typeof A=="number"||typeof A=="boolean"?w[I]=A:w[I]=A.clone(),!0;{let D=w[I];if(typeof A=="number"||typeof A=="boolean"){if(D!==A)return w[I]=A,!0}else if(D.equals(A)===!1)return D.copy(A),!0}return!1}function g(_){let y=_.uniforms,M=0,w=16;for(let I=0,D=y.length;I<D;I++){let T=Array.isArray(y[I])?y[I]:[y[I]];for(let S=0,P=T.length;S<P;S++){let L=T[S],O=Array.isArray(L.value)?L.value:[L.value];for(let H=0,q=O.length;H<q;H++){let Y=O[H],he=b(Y),j=M%w,le=j%he.boundary,ce=j+le;M+=le,ce!==0&&w-ce<he.storage&&(M+=w-ce),L.__data=new Float32Array(he.storage/Float32Array.BYTES_PER_ELEMENT),L.__offset=M,M+=he.storage}}}let A=M%w;return A>0&&(M+=w-A),_.__size=M,_.__cache={},this}function b(_){let y={boundary:0,storage:0};return typeof _=="number"||typeof _=="boolean"?(y.boundary=4,y.storage=4):_.isVector2?(y.boundary=8,y.storage=8):_.isVector3||_.isColor?(y.boundary=16,y.storage=12):_.isVector4?(y.boundary=16,y.storage=16):_.isMatrix3?(y.boundary=48,y.storage=48):_.isMatrix4?(y.boundary=64,y.storage=64):_.isTexture?Ze("WebGLRenderer: Texture samplers can not be part of an uniforms group."):Ze("WebGLRenderer: Unsupported uniform value type.",_),y}function m(_){let y=_.target;y.removeEventListener("dispose",m);let M=a.indexOf(y.__bindingPointIndex);a.splice(M,1),i.deleteBuffer(r[y.id]),delete r[y.id],delete s[y.id]}function d(){for(let _ in r)i.deleteBuffer(r[_]);a=[],r={},s={}}return{bind:c,update:u,dispose:d}}var O_=new Uint16Array([11481,15204,11534,15171,11808,15015,12385,14843,12894,14716,13396,14600,13693,14483,13976,14366,14237,14171,14405,13961,14511,13770,14605,13598,14687,13444,14760,13305,14822,13066,14876,12857,14923,12675,14963,12517,14997,12379,15025,12230,15049,12023,15070,11843,15086,11687,15100,11551,15111,11433,15120,11330,15127,11217,15132,11060,15135,10922,15138,10801,15139,10695,15139,10600,13012,14923,13020,14917,13064,14886,13176,14800,13349,14666,13513,14526,13724,14398,13960,14230,14200,14020,14383,13827,14488,13651,14583,13491,14667,13348,14740,13132,14803,12908,14856,12713,14901,12542,14938,12394,14968,12241,14992,12017,15010,11822,15024,11654,15034,11507,15041,11380,15044,11269,15044,11081,15042,10913,15037,10764,15031,10635,15023,10520,15014,10419,15003,10330,13657,14676,13658,14673,13670,14660,13698,14622,13750,14547,13834,14442,13956,14317,14112,14093,14291,13889,14407,13704,14499,13538,14586,13389,14664,13201,14733,12966,14792,12758,14842,12577,14882,12418,14915,12272,14940,12033,14959,11826,14972,11646,14980,11490,14983,11355,14983,11212,14979,11008,14971,10830,14961,10675,14950,10540,14936,10420,14923,10315,14909,10204,14894,10041,14089,14460,14090,14459,14096,14452,14112,14431,14141,14388,14186,14305,14252,14130,14341,13941,14399,13756,14467,13585,14539,13430,14610,13272,14677,13026,14737,12808,14790,12617,14833,12449,14869,12303,14896,12065,14916,11845,14929,11655,14937,11490,14939,11347,14936,11184,14930,10970,14921,10783,14912,10621,14900,10480,14885,10356,14867,10247,14848,10062,14827,9894,14805,9745,14400,14208,14400,14206,14402,14198,14406,14174,14415,14122,14427,14035,14444,13913,14469,13767,14504,13613,14548,13463,14598,13324,14651,13082,14704,12858,14752,12658,14795,12483,14831,12330,14860,12106,14881,11875,14895,11675,14903,11501,14905,11351,14903,11178,14900,10953,14892,10757,14880,10589,14865,10442,14847,10313,14827,10162,14805,9965,14782,9792,14757,9642,14731,9507,14562,13883,14562,13883,14563,13877,14566,13862,14570,13830,14576,13773,14584,13689,14595,13582,14613,13461,14637,13336,14668,13120,14704,12897,14741,12695,14776,12516,14808,12358,14835,12150,14856,11910,14870,11701,14878,11519,14882,11361,14884,11187,14880,10951,14871,10748,14858,10572,14842,10418,14823,10286,14801,10099,14777,9897,14751,9722,14725,9567,14696,9430,14666,9309,14702,13604,14702,13604,14702,13600,14703,13591,14705,13570,14707,13533,14709,13477,14712,13400,14718,13305,14727,13106,14743,12907,14762,12716,14784,12539,14807,12380,14827,12190,14844,11943,14855,11727,14863,11539,14870,11376,14871,11204,14868,10960,14858,10748,14845,10565,14829,10406,14809,10269,14786,10058,14761,9852,14734,9671,14705,9512,14674,9374,14641,9253,14608,9076,14821,13366,14821,13365,14821,13364,14821,13358,14821,13344,14821,13320,14819,13252,14817,13145,14815,13011,14814,12858,14817,12698,14823,12539,14832,12389,14841,12214,14850,11968,14856,11750,14861,11558,14866,11390,14867,11226,14862,10972,14853,10754,14840,10565,14823,10401,14803,10259,14780,10032,14754,9820,14725,9635,14694,9473,14661,9333,14627,9203,14593,8988,14557,8798,14923,13014,14922,13014,14922,13012,14922,13004,14920,12987,14919,12957,14915,12907,14909,12834,14902,12738,14894,12623,14888,12498,14883,12370,14880,12203,14878,11970,14875,11759,14873,11569,14874,11401,14872,11243,14865,10986,14855,10762,14842,10568,14825,10401,14804,10255,14781,10017,14754,9799,14725,9611,14692,9445,14658,9301,14623,9139,14587,8920,14548,8729,14509,8562,15008,12672,15008,12672,15008,12671,15007,12667,15005,12656,15001,12637,14997,12605,14989,12556,14978,12490,14966,12407,14953,12313,14940,12136,14927,11934,14914,11742,14903,11563,14896,11401,14889,11247,14879,10992,14866,10767,14851,10570,14833,10400,14812,10252,14789,10007,14761,9784,14731,9592,14698,9424,14663,9279,14627,9088,14588,8868,14548,8676,14508,8508,14467,8360,15080,12386,15080,12386,15079,12385,15078,12383,15076,12378,15072,12367,15066,12347,15057,12315,15045,12253,15030,12138,15012,11998,14993,11845,14972,11685,14951,11530,14935,11383,14920,11228,14904,10981,14887,10762,14870,10567,14850,10397,14827,10248,14803,9997,14774,9771,14743,9578,14710,9407,14674,9259,14637,9048,14596,8826,14555,8632,14514,8464,14471,8317,14427,8182,15139,12008,15139,12008,15138,12008,15137,12007,15135,12003,15130,11990,15124,11969,15115,11929,15102,11872,15086,11794,15064,11693,15041,11581,15013,11459,14987,11336,14966,11170,14944,10944,14921,10738,14898,10552,14875,10387,14850,10239,14824,9983,14794,9758,14762,9563,14728,9392,14692,9244,14653,9014,14611,8791,14569,8597,14526,8427,14481,8281,14436,8110,14391,7885,15188,11617,15188,11617,15187,11617,15186,11618,15183,11617,15179,11612,15173,11601,15163,11581,15150,11546,15133,11495,15110,11427,15083,11346,15051,11246,15024,11057,14996,10868,14967,10687,14938,10517,14911,10362,14882,10206,14853,9956,14821,9737,14787,9543,14752,9375,14715,9228,14675,8980,14632,8760,14589,8565,14544,8395,14498,8248,14451,8049,14404,7824,14357,7630,15228,11298,15228,11298,15227,11299,15226,11301,15223,11303,15219,11302,15213,11299,15204,11290,15191,11271,15174,11217,15150,11129,15119,11015,15087,10886,15057,10744,15024,10599,14990,10455,14957,10318,14924,10143,14891,9911,14856,9701,14820,9516,14782,9352,14744,9200,14703,8946,14659,8725,14615,8533,14568,8366,14521,8220,14472,7992,14423,7770,14374,7578,14315,7408,15260,10819,15260,10819,15259,10822,15258,10826,15256,10832,15251,10836,15246,10841,15237,10838,15225,10821,15207,10788,15183,10734,15151,10660,15120,10571,15087,10469,15049,10359,15012,10249,14974,10041,14937,9837,14900,9647,14860,9475,14820,9320,14779,9147,14736,8902,14691,8688,14646,8499,14598,8335,14549,8189,14499,7940,14448,7720,14397,7529,14347,7363,14256,7218,15285,10410,15285,10411,15285,10413,15284,10418,15282,10425,15278,10434,15272,10442,15264,10449,15252,10445,15235,10433,15210,10403,15179,10358,15149,10301,15113,10218,15073,10059,15033,9894,14991,9726,14951,9565,14909,9413,14865,9273,14822,9073,14777,8845,14730,8641,14682,8459,14633,8300,14583,8129,14531,7883,14479,7670,14426,7482,14373,7321,14305,7176,14201,6939,15305,9939,15305,9940,15305,9945,15304,9955,15302,9967,15298,9989,15293,10010,15286,10033,15274,10044,15258,10045,15233,10022,15205,9975,15174,9903,15136,9808,15095,9697,15053,9578,15009,9451,14965,9327,14918,9198,14871,8973,14825,8766,14775,8579,14725,8408,14675,8259,14622,8058,14569,7821,14515,7615,14460,7435,14405,7276,14350,7108,14256,6866,14149,6653,15321,9444,15321,9445,15321,9448,15320,9458,15317,9470,15314,9490,15310,9515,15302,9540,15292,9562,15276,9579,15251,9577,15226,9559,15195,9519,15156,9463,15116,9389,15071,9304,15025,9208,14978,9023,14927,8838,14878,8661,14827,8496,14774,8344,14722,8206,14667,7973,14612,7749,14556,7555,14499,7382,14443,7229,14385,7025,14322,6791,14210,6588,14100,6409,15333,8920,15333,8921,15332,8927,15332,8943,15329,8965,15326,9002,15322,9048,15316,9106,15307,9162,15291,9204,15267,9221,15244,9221,15212,9196,15175,9134,15133,9043,15088,8930,15040,8801,14990,8665,14938,8526,14886,8391,14830,8261,14775,8087,14719,7866,14661,7664,14603,7482,14544,7322,14485,7178,14426,6936,14367,6713,14281,6517,14166,6348,14054,6198,15341,8360,15341,8361,15341,8366,15341,8379,15339,8399,15336,8431,15332,8473,15326,8527,15318,8585,15302,8632,15281,8670,15258,8690,15227,8690,15191,8664,15149,8612,15104,8543,15055,8456,15001,8360,14948,8259,14892,8122,14834,7923,14776,7734,14716,7558,14656,7397,14595,7250,14534,7070,14472,6835,14410,6628,14350,6443,14243,6283,14125,6135,14010,5889,15348,7715,15348,7717,15348,7725,15347,7745,15345,7780,15343,7836,15339,7905,15334,8e3,15326,8103,15310,8193,15293,8239,15270,8270,15240,8287,15204,8283,15163,8260,15118,8223,15067,8143,15014,8014,14958,7873,14899,7723,14839,7573,14778,7430,14715,7293,14652,7164,14588,6931,14524,6720,14460,6531,14396,6362,14330,6210,14207,6015,14086,5781,13969,5576,15352,7114,15352,7116,15352,7128,15352,7159,15350,7195,15348,7237,15345,7299,15340,7374,15332,7457,15317,7544,15301,7633,15280,7703,15251,7754,15216,7775,15176,7767,15131,7733,15079,7670,15026,7588,14967,7492,14906,7387,14844,7278,14779,7171,14714,6965,14648,6770,14581,6587,14515,6420,14448,6269,14382,6123,14299,5881,14172,5665,14049,5477,13929,5310,15355,6329,15355,6330,15355,6339,15355,6362,15353,6410,15351,6472,15349,6572,15344,6688,15337,6835,15323,6985,15309,7142,15287,7220,15260,7277,15226,7310,15188,7326,15142,7318,15090,7285,15036,7239,14976,7177,14914,7045,14849,6892,14782,6736,14714,6581,14645,6433,14576,6293,14506,6164,14438,5946,14369,5733,14270,5540,14140,5369,14014,5216,13892,5043,15357,5483,15357,5484,15357,5496,15357,5528,15356,5597,15354,5692,15351,5835,15347,6011,15339,6195,15328,6317,15314,6446,15293,6566,15268,6668,15235,6746,15197,6796,15152,6811,15101,6790,15046,6748,14985,6673,14921,6583,14854,6479,14785,6371,14714,6259,14643,6149,14571,5946,14499,5750,14428,5567,14358,5401,14242,5250,14109,5111,13980,4870,13856,4657,15359,4555,15359,4557,15358,4573,15358,4633,15357,4715,15355,4841,15353,5061,15349,5216,15342,5391,15331,5577,15318,5770,15299,5967,15274,6150,15243,6223,15206,6280,15161,6310,15111,6317,15055,6300,14994,6262,14928,6208,14860,6141,14788,5994,14715,5838,14641,5684,14566,5529,14492,5384,14418,5247,14346,5121,14216,4892,14079,4682,13948,4496,13822,4330,15359,3498,15359,3501,15359,3520,15359,3598,15358,3719,15356,3860,15355,4137,15351,4305,15344,4563,15334,4809,15321,5116,15303,5273,15280,5418,15250,5547,15214,5653,15170,5722,15120,5761,15064,5763,15002,5733,14935,5673,14865,5597,14792,5504,14716,5400,14640,5294,14563,5185,14486,5041,14410,4841,14335,4655,14191,4482,14051,4325,13918,4183,13790,4012,15360,2282,15360,2285,15360,2306,15360,2401,15359,2547,15357,2748,15355,3103,15352,3349,15345,3675,15336,4020,15324,4272,15307,4496,15285,4716,15255,4908,15220,5086,15178,5170,15128,5214,15072,5234,15010,5231,14943,5206,14871,5166,14796,5102,14718,4971,14639,4833,14559,4687,14480,4541,14402,4401,14315,4268,14167,4142,14025,3958,13888,3747,13759,3556,15360,923,15360,925,15360,946,15360,1052,15359,1214,15357,1494,15356,1892,15352,2274,15346,2663,15338,3099,15326,3393,15309,3679,15288,3980,15260,4183,15226,4325,15185,4437,15136,4517,15080,4570,15018,4591,14950,4581,14877,4545,14800,4485,14720,4411,14638,4325,14556,4231,14475,4136,14395,3988,14297,3803,14145,3628,13999,3465,13861,3314,13729,3177,15360,263,15360,264,15360,272,15360,325,15359,407,15358,548,15356,780,15352,1144,15347,1580,15339,2099,15328,2425,15312,2795,15292,3133,15264,3329,15232,3517,15191,3689,15143,3819,15088,3923,15025,3978,14956,3999,14882,3979,14804,3931,14722,3855,14639,3756,14554,3645,14470,3529,14388,3409,14279,3289,14124,3173,13975,3055,13834,2848,13701,2658,15360,49,15360,49,15360,52,15360,75,15359,111,15358,201,15356,283,15353,519,15348,726,15340,1045,15329,1415,15314,1795,15295,2173,15269,2410,15237,2649,15197,2866,15150,3054,15095,3140,15032,3196,14963,3228,14888,3236,14808,3224,14725,3191,14639,3146,14553,3088,14466,2976,14382,2836,14262,2692,14103,2549,13952,2409,13808,2278,13674,2154,15360,4,15360,4,15360,4,15360,13,15359,33,15358,59,15357,112,15353,199,15348,302,15341,456,15331,628,15316,827,15297,1082,15272,1332,15241,1601,15202,1851,15156,2069,15101,2172,15039,2256,14970,2314,14894,2348,14813,2358,14728,2344,14640,2311,14551,2263,14463,2203,14376,2133,14247,2059,14084,1915,13930,1761,13784,1609,13648,1464,15360,0,15360,0,15360,0,15360,3,15359,18,15358,26,15357,53,15354,80,15348,97,15341,165,15332,238,15318,326,15299,427,15275,529,15245,654,15207,771,15161,885,15108,994,15046,1089,14976,1170,14900,1229,14817,1266,14731,1284,14641,1282,14550,1260,14460,1223,14370,1174,14232,1116,14066,1050,13909,981,13761,910,13623,839]),xi=null;function z_(){return xi===null&&(xi=new St(O_,32,32,Tn,_t),xi.minFilter=ft,xi.magFilter=ft,xi.wrapS=Lt,xi.wrapT=Lt,xi.generateMipmaps=!1,xi.needsUpdate=!0),xi}var mc=class{constructor(e={}){let{canvas:t=Xf(),context:n=null,depth:r=!0,stencil:s=!1,alpha:a=!1,antialias:o=!1,premultipliedAlpha:c=!0,preserveDrawingBuffer:u=!1,powerPreference:f="default",failIfMajorPerformanceCaveat:h=!1,reversedDepthBuffer:l=!1}=e;this.isWebGLRenderer=!0;let p;if(n!==null){if(typeof WebGLRenderingContext<"u"&&n instanceof WebGLRenderingContext)throw new Error("THREE.WebGLRenderer: WebGL 1 is not supported since r163.");p=n.getContextAttributes().alpha}else p=a;let g=new Set([Bi,Ui,jr]),b=new Set([dn,xn,Li,Kr,Uo,Bo]),m=new Uint32Array(4),d=new Int32Array(4),_=null,y=null,M=[],w=[];this.domElement=t,this.debug={checkShaderErrors:!0,onShaderError:null},this.autoClear=!0,this.autoClearColor=!0,this.autoClearDepth=!0,this.autoClearStencil=!0,this.sortObjects=!0,this.clippingPlanes=[],this.localClippingEnabled=!1,this.toneMapping=qn,this.toneMappingExposure=1,this.transmissionResolutionScale=1;let A=this,I=!1;this._outputColorSpace=ln;let D=0,T=0,S=null,P=-1,L=null,O=new ht,H=new ht,q=null,Y=new Ye(0),he=0,j=t.width,le=t.height,ce=1,we=null,Ce=null,ke=new ht(0,0,j,le),ct=new ht(0,0,j,le),nt=!1,K=new Zr,re=!1,be=!1,We=new Xe,Pe=new k,Qe=new ht,Rt={background:null,fog:null,environment:null,overrideMaterial:null,isScene:!0},tt=!1;function wt(){return S===null?ce:1}let G=n;function at(v,F){return t.getContext(v,F)}try{let v={alpha:!0,depth:r,stencil:s,antialias:o,premultipliedAlpha:c,preserveDrawingBuffer:u,powerPreference:f,failIfMajorPerformanceCaveat:h};if("setAttribute"in t&&t.setAttribute("data-engine",`three.js r${"181"}`),t.addEventListener("webglcontextlost",me,!1),t.addEventListener("webglcontextrestored",se,!1),t.addEventListener("webglcontextcreationerror",Ee,!1),G===null){let F="webgl2";if(G=at(F,v),G===null)throw at(F)?new Error("Error creating WebGL context with your selected attributes."):new Error("Error creating WebGL context.")}}catch(v){throw v("WebGLRenderer: "+v.message),v}let ot,yt,Ae,It,Be,$e,N,E,$,ie,ue,te,Fe,xe,Oe,De,fe,de,Re,ze,ve,Ie,V,_e;function J(){ot=new tv(G),ot.init(),Ie=new D_(G,ot),yt=new qx(G,ot,e,Ie),Ae=new I_(G,ot),yt.reversedDepthBuffer&&l&&Ae.buffers.depth.setReversed(!0),It=new rv(G),Be=new x_,$e=new P_(G,ot,Ae,Be,yt,Ie,It),N=new Zx(A),E=new ev(A),$=new c0(G),V=new Wx(G,$),ie=new nv(G,$,It,V),ue=new av(G,ie,$,It),Re=new sv(G,yt,$e),De=new Yx(Be),te=new g_(A,N,E,ot,yt,V,De),Fe=new U_(A,Be),xe=new __,Oe=new w_(ot),de=new Gx(A,N,E,Ae,ue,p,c),fe=new C_(A,ue,yt),_e=new B_(G,It,yt,Ae),ze=new Xx(G,ot,It),ve=new iv(G,ot,It),It.programs=te.programs,A.capabilities=yt,A.extensions=ot,A.properties=Be,A.renderLists=xe,A.shadowMap=fe,A.state=Ae,A.info=It}J();let ge=new Zu(A,G);this.xr=ge,this.getContext=function(){return G},this.getContextAttributes=function(){return G.getContextAttributes()},this.forceContextLoss=function(){let v=ot.get("WEBGL_lose_context");v&&v.loseContext()},this.forceContextRestore=function(){let v=ot.get("WEBGL_lose_context");v&&v.restoreContext()},this.getPixelRatio=function(){return ce},this.setPixelRatio=function(v){v!==void 0&&(ce=v,this.setSize(j,le,!1))},this.getSize=function(v){return v.set(j,le)},this.setSize=function(v,F,z=!0){if(ge.isPresenting){Ze("WebGLRenderer: Can't change size while VR device is presenting.");return}j=v,le=F,t.width=Math.floor(v*ce),t.height=Math.floor(F*ce),z===!0&&(t.style.width=v+"px",t.style.height=F+"px"),this.setViewport(0,0,v,F)},this.getDrawingBufferSize=function(v){return v.set(j*ce,le*ce).floor()},this.setDrawingBufferSize=function(v,F,z){j=v,le=F,ce=z,t.width=Math.floor(v*z),t.height=Math.floor(F*z),this.setViewport(0,0,v,F)},this.getCurrentViewport=function(v){return v.copy(O)},this.getViewport=function(v){return v.copy(ke)},this.setViewport=function(v,F,z,R){v.isVector4?ke.set(v.x,v.y,v.z,v.w):ke.set(v,F,z,R),Ae.viewport(O.copy(ke).multiplyScalar(ce).round())},this.getScissor=function(v){return v.copy(ct)},this.setScissor=function(v,F,z,R){v.isVector4?ct.set(v.x,v.y,v.z,v.w):ct.set(v,F,z,R),Ae.scissor(H.copy(ct).multiplyScalar(ce).round())},this.getScissorTest=function(){return nt},this.setScissorTest=function(v){Ae.setScissorTest(nt=v)},this.setOpaqueSort=function(v){we=v},this.setTransparentSort=function(v){Ce=v},this.getClearColor=function(v){return v.copy(de.getClearColor())},this.setClearColor=function(){de.setClearColor(...arguments)},this.getClearAlpha=function(){return de.getClearAlpha()},this.setClearAlpha=function(){de.setClearAlpha(...arguments)},this.clear=function(v=!0,F=!0,z=!0){let R=0;if(v){let U=!1;if(S!==null){let W=S.texture.format;U=g.has(W)}if(U){let W=S.texture.type,X=b.has(W),Z=de.getClearColor(),Q=de.getClearAlpha(),ee=Z.r,ne=Z.g,ae=Z.b;X?(m[0]=ee,m[1]=ne,m[2]=ae,m[3]=Q,G.clearBufferuiv(G.COLOR,0,m)):(d[0]=ee,d[1]=ne,d[2]=ae,d[3]=Q,G.clearBufferiv(G.COLOR,0,d))}else R|=G.COLOR_BUFFER_BIT}F&&(R|=G.DEPTH_BUFFER_BIT),z&&(R|=G.STENCIL_BUFFER_BIT,this.state.buffers.stencil.setMask(4294967295)),G.clear(R)},this.clearColor=function(){this.clear(!0,!1,!1)},this.clearDepth=function(){this.clear(!1,!0,!1)},this.clearStencil=function(){this.clear(!1,!1,!0)},this.dispose=function(){t.removeEventListener("webglcontextlost",me,!1),t.removeEventListener("webglcontextrestored",se,!1),t.removeEventListener("webglcontextcreationerror",Ee,!1),de.dispose(),xe.dispose(),Oe.dispose(),Be.dispose(),N.dispose(),E.dispose(),ue.dispose(),V.dispose(),_e.dispose(),te.dispose(),ge.dispose(),ge.removeEventListener("sessionstart",Da),ge.removeEventListener("sessionend",Fa),ii.stop()};function me(v){v.preventDefault(),Pu("WebGLRenderer: Context Lost."),I=!0}function se(){Pu("WebGLRenderer: Context Restored."),I=!1;let v=It.autoReset,F=fe.enabled,z=fe.autoUpdate,R=fe.needsUpdate,U=fe.type;J(),It.autoReset=v,fe.enabled=F,fe.autoUpdate=z,fe.needsUpdate=R,fe.type=U}function Ee(v){ut("WebGLRenderer: A WebGL context could not be created. Reason: ",v.statusMessage)}function Je(v){let F=v.target;F.removeEventListener("dispose",Je),At(F)}function At(v){vt(v),Be.remove(v)}function vt(v){let F=Be.get(v).programs;F!==void 0&&(F.forEach(function(z){te.releaseProgram(z)}),v.isShaderMaterial&&te.releaseShaderCache(v))}this.renderBufferDirect=function(v,F,z,R,U,W){F===null&&(F=Rt);let X=U.isMesh&&U.matrixWorld.determinant()<0,Z=Dl(v,F,z,R,U);Ae.setMaterial(R,X);let Q=z.index,ee=1;if(R.wireframe===!0){if(Q=ie.getWireframeAttribute(z),Q===void 0)return;ee=2}let ne=z.drawRange,ae=z.attributes.position,oe=ne.start*ee,pe=(ne.start+ne.count)*ee;W!==null&&(oe=Math.max(oe,W.start*ee),pe=Math.min(pe,(W.start+W.count)*ee)),Q!==null?(oe=Math.max(oe,0),pe=Math.min(pe,Q.count)):ae!=null&&(oe=Math.max(oe,0),pe=Math.min(pe,ae.count));let Me=pe-oe;if(Me<0||Me===1/0)return;V.setup(U,R,Z,z,Q);let Ne,Ue=ze;if(Q!==null&&(Ne=$.get(Q),Ue=ve,Ue.setIndex(Ne)),U.isMesh)R.wireframe===!0?(Ae.setLineWidth(R.wireframeLinewidth*wt()),Ue.setMode(G.LINES)):Ue.setMode(G.TRIANGLES);else if(U.isLine){let Te=R.linewidth;Te===void 0&&(Te=1),Ae.setLineWidth(Te*wt()),U.isLineSegments?Ue.setMode(G.LINES):U.isLineLoop?Ue.setMode(G.LINE_LOOP):Ue.setMode(G.LINE_STRIP)}else U.isPoints?Ue.setMode(G.POINTS):U.isSprite&&Ue.setMode(G.TRIANGLES);if(U.isBatchedMesh)if(U._multiDrawInstances!==null)Gr("WebGLRenderer: renderMultiDrawInstances has been deprecated and will be removed in r184. Append to renderMultiDraw arguments and use indirection."),Ue.renderMultiDrawInstances(U._multiDrawStarts,U._multiDrawCounts,U._multiDrawCount,U._multiDrawInstances);else if(ot.get("WEBGL_multi_draw"))Ue.renderMultiDraw(U._multiDrawStarts,U._multiDrawCounts,U._multiDrawCount);else{let Te=U._multiDrawStarts,Ve=U._multiDrawCounts,ye=U._multiDrawCount,lt=Q?$.get(Q).bytesPerElement:1,Dt=Be.get(R).currentProgram.getUniforms();for(let st=0;st<ye;st++)Dt.setValue(G,"_gl_DrawID",st),Ue.render(Te[st]/lt,Ve[st])}else if(U.isInstancedMesh)Ue.renderInstances(oe,Me,U.count);else if(z.isInstancedBufferGeometry){let Te=z._maxInstanceCount!==void 0?z._maxInstanceCount:1/0,Ve=Math.min(z.instanceCount,Te);Ue.renderInstances(oe,Me,Ve)}else Ue.render(oe,Me)};function Fn(v,F,z){v.transparent===!0&&v.side===fn&&v.forceSinglePass===!1?(v.side=Zt,v.needsUpdate=!0,Sr(v,F,z),v.side=Mn,v.needsUpdate=!0,Sr(v,F,z),v.side=fn):Sr(v,F,z)}this.compile=function(v,F,z=null){z===null&&(z=v),y=Oe.get(z),y.init(F),w.push(y),z.traverseVisible(function(U){U.isLight&&U.layers.test(F.layers)&&(y.pushLight(U),U.castShadow&&y.pushShadow(U))}),v!==z&&v.traverseVisible(function(U){U.isLight&&U.layers.test(F.layers)&&(y.pushLight(U),U.castShadow&&y.pushShadow(U))}),y.setupLights();let R=new Set;return v.traverse(function(U){if(!(U.isMesh||U.isPoints||U.isLine||U.isSprite))return;let W=U.material;if(W)if(Array.isArray(W))for(let X=0;X<W.length;X++){let Z=W[X];Fn(Z,z,U),R.add(Z)}else Fn(W,z,U),R.add(W)}),y=w.pop(),R},this.compileAsync=function(v,F,z=null){let R=this.compile(v,F,z);return new Promise(U=>{function W(){if(R.forEach(function(X){Be.get(X).currentProgram.isReady()&&R.delete(X)}),R.size===0){U(v);return}setTimeout(W,10)}ot.get("KHR_parallel_shader_compile")!==null?W():setTimeout(W,10)})};let An=null;function Pl(v){An&&An(v)}function Da(){ii.stop()}function Fa(){ii.start()}let ii=new vd;ii.setAnimationLoop(Pl),typeof self<"u"&&ii.setContext(self),this.setAnimationLoop=function(v){An=v,ge.setAnimationLoop(v),v===null?ii.stop():ii.start()},ge.addEventListener("sessionstart",Da),ge.addEventListener("sessionend",Fa),this.render=function(v,F){if(F!==void 0&&F.isCamera!==!0){ut("WebGLRenderer.render: camera is not an instance of THREE.Camera.");return}if(I===!0)return;if(v.matrixWorldAutoUpdate===!0&&v.updateMatrixWorld(),F.parent===null&&F.matrixWorldAutoUpdate===!0&&F.updateMatrixWorld(),ge.enabled===!0&&ge.isPresenting===!0&&(ge.cameraAutoUpdate===!0&&ge.updateCamera(F),F=ge.getCamera()),v.isScene===!0&&v.onBeforeRender(A,v,F,S),y=Oe.get(v,w.length),y.init(F),w.push(y),We.multiplyMatrices(F.projectionMatrix,F.matrixWorldInverse),K.setFromProjectionMatrix(We,Hn,F.reversedDepth),be=this.localClippingEnabled,re=De.init(this.clippingPlanes,be),_=xe.get(v,M.length),_.init(),M.push(_),ge.enabled===!0&&ge.isPresenting===!0){let W=A.xr.getDepthSensingMesh();W!==null&&Ts(W,F,-1/0,A.sortObjects)}Ts(v,F,0,A.sortObjects),_.finish(),A.sortObjects===!0&&_.sort(we,Ce),tt=ge.enabled===!1||ge.isPresenting===!1||ge.hasDepthSensing()===!1,tt&&de.addToRenderList(_,v),this.info.render.frame++,re===!0&&De.beginShadows();let z=y.state.shadowsArray;fe.render(z,v,F),re===!0&&De.endShadows(),this.info.autoReset===!0&&this.info.reset();let R=_.opaque,U=_.transmissive;if(y.setupLights(),F.isArrayCamera){let W=F.cameras;if(U.length>0)for(let X=0,Z=W.length;X<Z;X++){let Q=W[X];La(R,U,v,Q)}tt&&de.render(v);for(let X=0,Z=W.length;X<Z;X++){let Q=W[X];ws(_,v,Q,Q.viewport)}}else U.length>0&&La(R,U,v,F),tt&&de.render(v),ws(_,v,F);S!==null&&T===0&&($e.updateMultisampleRenderTarget(S),$e.updateRenderTargetMipmap(S)),v.isScene===!0&&v.onAfterRender(A,v,F),V.resetDefaultState(),P=-1,L=null,w.pop(),w.length>0?(y=w[w.length-1],re===!0&&De.setGlobalState(A.clippingPlanes,y.state.camera)):y=null,M.pop(),M.length>0?_=M[M.length-1]:_=null};function Ts(v,F,z,R){if(v.visible===!1)return;if(v.layers.test(F.layers)){if(v.isGroup)z=v.renderOrder;else if(v.isLOD)v.autoUpdate===!0&&v.update(F);else if(v.isLight)y.pushLight(v),v.castShadow&&y.pushShadow(v);else if(v.isSprite){if(!v.frustumCulled||K.intersectsSprite(v)){R&&Qe.setFromMatrixPosition(v.matrixWorld).applyMatrix4(We);let X=ue.update(v),Z=v.material;Z.visible&&_.push(v,X,Z,z,Qe.z,null)}}else if((v.isMesh||v.isLine||v.isPoints)&&(!v.frustumCulled||K.intersectsObject(v))){let X=ue.update(v),Z=v.material;if(R&&(v.boundingSphere!==void 0?(v.boundingSphere===null&&v.computeBoundingSphere(),Qe.copy(v.boundingSphere.center)):(X.boundingSphere===null&&X.computeBoundingSphere(),Qe.copy(X.boundingSphere.center)),Qe.applyMatrix4(v.matrixWorld).applyMatrix4(We)),Array.isArray(Z)){let Q=X.groups;for(let ee=0,ne=Q.length;ee<ne;ee++){let ae=Q[ee],oe=Z[ae.materialIndex];oe&&oe.visible&&_.push(v,X,oe,z,Qe.z,ae)}}else Z.visible&&_.push(v,X,Z,z,Qe.z,null)}}let W=v.children;for(let X=0,Z=W.length;X<Z;X++)Ts(W[X],F,z,R)}function ws(v,F,z,R){let{opaque:U,transmissive:W,transparent:X}=v;y.setupLightsView(z),re===!0&&De.setGlobalState(A.clippingPlanes,z),R&&Ae.viewport(O.copy(R)),U.length>0&&br(U,F,z),W.length>0&&br(W,F,z),X.length>0&&br(X,F,z),Ae.buffers.depth.setTest(!0),Ae.buffers.depth.setMask(!0),Ae.buffers.color.setMask(!0),Ae.setPolygonOffset(!1)}function La(v,F,z,R){if((z.isScene===!0?z.overrideMaterial:null)!==null)return;y.state.transmissionRenderTarget[R.id]===void 0&&(y.state.transmissionRenderTarget[R.id]=new Yt(1,1,{generateMipmaps:!0,type:ot.has("EXT_color_buffer_half_float")||ot.has("EXT_color_buffer_float")?_t:dn,minFilter:mi,samples:4,stencilBuffer:s,resolveDepthBuffer:!1,resolveStencilBuffer:!1,colorSpace:dt.workingColorSpace}));let W=y.state.transmissionRenderTarget[R.id],X=R.viewport||O;W.setSize(X.z*A.transmissionResolutionScale,X.w*A.transmissionResolutionScale);let Z=A.getRenderTarget(),Q=A.getActiveCubeFace(),ee=A.getActiveMipmapLevel();A.setRenderTarget(W),A.getClearColor(Y),he=A.getClearAlpha(),he<1&&A.setClearColor(16777215,.5),A.clear(),tt&&de.render(z);let ne=A.toneMapping;A.toneMapping=qn;let ae=R.viewport;if(R.viewport!==void 0&&(R.viewport=void 0),y.setupLightsView(R),re===!0&&De.setGlobalState(A.clippingPlanes,R),br(v,z,R),$e.updateMultisampleRenderTarget(W),$e.updateRenderTargetMipmap(W),ot.has("WEBGL_multisampled_render_to_texture")===!1){let oe=!1;for(let pe=0,Me=F.length;pe<Me;pe++){let Ne=F[pe],{object:Ue,geometry:Te,material:Ve,group:ye}=Ne;if(Ve.side===fn&&Ue.layers.test(R.layers)){let lt=Ve.side;Ve.side=Zt,Ve.needsUpdate=!0,Na(Ue,z,R,Te,Ve,ye),Ve.side=lt,Ve.needsUpdate=!0,oe=!0}}oe===!0&&($e.updateMultisampleRenderTarget(W),$e.updateRenderTargetMipmap(W))}A.setRenderTarget(Z,Q,ee),A.setClearColor(Y,he),ae!==void 0&&(R.viewport=ae),A.toneMapping=ne}function br(v,F,z){let R=F.isScene===!0?F.overrideMaterial:null;for(let U=0,W=v.length;U<W;U++){let X=v[U],{object:Z,geometry:Q,group:ee}=X,ne=X.material;ne.allowOverride===!0&&R!==null&&(ne=R),Z.layers.test(z.layers)&&Na(Z,F,z,Q,ne,ee)}}function Na(v,F,z,R,U,W){v.onBeforeRender(A,F,z,R,U,W),v.modelViewMatrix.multiplyMatrices(z.matrixWorldInverse,v.matrixWorld),v.normalMatrix.getNormalMatrix(v.modelViewMatrix),U.onBeforeRender(A,F,z,R,v,W),U.transparent===!0&&U.side===fn&&U.forceSinglePass===!1?(U.side=Zt,U.needsUpdate=!0,A.renderBufferDirect(z,F,R,U,v,W),U.side=Mn,U.needsUpdate=!0,A.renderBufferDirect(z,F,R,U,v,W),U.side=fn):A.renderBufferDirect(z,F,R,U,v,W),v.onAfterRender(A,F,z,R,U,W)}function Sr(v,F,z){F.isScene!==!0&&(F=Rt);let R=Be.get(v),U=y.state.lights,W=y.state.shadowsArray,X=U.state.version,Z=te.getParameters(v,U.state,W,F,z),Q=te.getProgramCacheKey(Z),ee=R.programs;R.environment=v.isMeshStandardMaterial?F.environment:null,R.fog=F.fog,R.envMap=(v.isMeshStandardMaterial?E:N).get(v.envMap||R.environment),R.envMapRotation=R.environment!==null&&v.envMap===null?F.environmentRotation:v.envMapRotation,ee===void 0&&(v.addEventListener("dispose",Je),ee=new Map,R.programs=ee);let ne=ee.get(Q);if(ne!==void 0){if(R.currentProgram===ne&&R.lightsStateVersion===X)return Es(v,Z),ne}else Z.uniforms=te.getUniforms(v),v.onBeforeCompile(Z,A),ne=te.acquireProgram(Z,Q),ee.set(Q,ne),R.uniforms=Z.uniforms;let ae=R.uniforms;return(!v.isShaderMaterial&&!v.isRawShaderMaterial||v.clipping===!0)&&(ae.clippingPlanes=De.uniform),Es(v,Z),R.needsLights=Qn(v),R.lightsStateVersion=X,R.needsLights&&(ae.ambientLightColor.value=U.state.ambient,ae.lightProbe.value=U.state.probe,ae.directionalLights.value=U.state.directional,ae.directionalLightShadows.value=U.state.directionalShadow,ae.spotLights.value=U.state.spot,ae.spotLightShadows.value=U.state.spotShadow,ae.rectAreaLights.value=U.state.rectArea,ae.ltc_1.value=U.state.rectAreaLTC1,ae.ltc_2.value=U.state.rectAreaLTC2,ae.pointLights.value=U.state.point,ae.pointLightShadows.value=U.state.pointShadow,ae.hemisphereLights.value=U.state.hemi,ae.directionalShadowMap.value=U.state.directionalShadowMap,ae.directionalShadowMatrix.value=U.state.directionalShadowMatrix,ae.spotShadowMap.value=U.state.spotShadowMap,ae.spotLightMatrix.value=U.state.spotLightMatrix,ae.spotLightMap.value=U.state.spotLightMap,ae.pointShadowMap.value=U.state.pointShadowMap,ae.pointShadowMatrix.value=U.state.pointShadowMatrix),R.currentProgram=ne,R.uniformsList=null,ne}function As(v){if(v.uniformsList===null){let F=v.currentProgram.getUniforms();v.uniformsList=ts.seqWithValue(F.seq,v.uniforms)}return v.uniformsList}function Es(v,F){let z=Be.get(v);z.outputColorSpace=F.outputColorSpace,z.batching=F.batching,z.batchingColor=F.batchingColor,z.instancing=F.instancing,z.instancingColor=F.instancingColor,z.instancingMorph=F.instancingMorph,z.skinning=F.skinning,z.morphTargets=F.morphTargets,z.morphNormals=F.morphNormals,z.morphColors=F.morphColors,z.morphTargetsCount=F.morphTargetsCount,z.numClippingPlanes=F.numClippingPlanes,z.numIntersection=F.numClipIntersection,z.vertexAlphas=F.vertexAlphas,z.vertexTangents=F.vertexTangents,z.toneMapping=F.toneMapping}function Dl(v,F,z,R,U){F.isScene!==!0&&(F=Rt),$e.resetTextureUnits();let W=F.fog,X=R.isMeshStandardMaterial?F.environment:null,Z=S===null?A.outputColorSpace:S.isXRRenderTarget===!0?S.texture.colorSpace:Gt,Q=(R.isMeshStandardMaterial?E:N).get(R.envMap||X),ee=R.vertexColors===!0&&!!z.attributes.color&&z.attributes.color.itemSize===4,ne=!!z.attributes.tangent&&(!!R.normalMap||R.anisotropy>0),ae=!!z.morphAttributes.position,oe=!!z.morphAttributes.normal,pe=!!z.morphAttributes.color,Me=qn;R.toneMapped&&(S===null||S.isXRRenderTarget===!0)&&(Me=A.toneMapping);let Ne=z.morphAttributes.position||z.morphAttributes.normal||z.morphAttributes.color,Ue=Ne!==void 0?Ne.length:0,Te=Be.get(R),Ve=y.state.lights;if(re===!0&&(be===!0||v!==L)){let Pt=v===L&&R.id===P;De.setState(R,v,Pt)}let ye=!1;R.version===Te.__version?(Te.needsLights&&Te.lightsStateVersion!==Ve.state.version||Te.outputColorSpace!==Z||U.isBatchedMesh&&Te.batching===!1||!U.isBatchedMesh&&Te.batching===!0||U.isBatchedMesh&&Te.batchingColor===!0&&U.colorTexture===null||U.isBatchedMesh&&Te.batchingColor===!1&&U.colorTexture!==null||U.isInstancedMesh&&Te.instancing===!1||!U.isInstancedMesh&&Te.instancing===!0||U.isSkinnedMesh&&Te.skinning===!1||!U.isSkinnedMesh&&Te.skinning===!0||U.isInstancedMesh&&Te.instancingColor===!0&&U.instanceColor===null||U.isInstancedMesh&&Te.instancingColor===!1&&U.instanceColor!==null||U.isInstancedMesh&&Te.instancingMorph===!0&&U.morphTexture===null||U.isInstancedMesh&&Te.instancingMorph===!1&&U.morphTexture!==null||Te.envMap!==Q||R.fog===!0&&Te.fog!==W||Te.numClippingPlanes!==void 0&&(Te.numClippingPlanes!==De.numPlanes||Te.numIntersection!==De.numIntersection)||Te.vertexAlphas!==ee||Te.vertexTangents!==ne||Te.morphTargets!==ae||Te.morphNormals!==oe||Te.morphColors!==pe||Te.toneMapping!==Me||Te.morphTargetsCount!==Ue)&&(ye=!0):(ye=!0,Te.__version=R.version);let lt=Te.currentProgram;ye===!0&&(lt=Sr(R,F,U));let Dt=!1,st=!1,it=!1,Ge=lt.getUniforms(),Nt=Te.uniforms;if(Ae.useProgram(lt.program)&&(Dt=!0,st=!0,it=!0),R.id!==P&&(P=R.id,st=!0),Dt||L!==v){Ae.buffers.depth.getReversed()&&v.reversedDepth!==!0&&(v._reversedDepth=!0,v.updateProjectionMatrix()),Ge.setValue(G,"projectionMatrix",v.projectionMatrix),Ge.setValue(G,"viewMatrix",v.matrixWorldInverse);let qt=Ge.map.cameraPosition;qt!==void 0&&qt.setValue(G,Pe.setFromMatrixPosition(v.matrixWorld)),yt.logarithmicDepthBuffer&&Ge.setValue(G,"logDepthBufFC",2/(Math.log(v.far+1)/Math.LN2)),(R.isMeshPhongMaterial||R.isMeshToonMaterial||R.isMeshLambertMaterial||R.isMeshBasicMaterial||R.isMeshStandardMaterial||R.isShaderMaterial)&&Ge.setValue(G,"isOrthographic",v.isOrthographicCamera===!0),L!==v&&(L=v,st=!0,it=!0)}if(U.isSkinnedMesh){Ge.setOptional(G,U,"bindMatrix"),Ge.setOptional(G,U,"bindMatrixInverse");let Pt=U.skeleton;Pt&&(Pt.boneTexture===null&&Pt.computeBoneTexture(),Ge.setValue(G,"boneTexture",Pt.boneTexture,$e))}U.isBatchedMesh&&(Ge.setOptional(G,U,"batchingTexture"),Ge.setValue(G,"batchingTexture",U._matricesTexture,$e),Ge.setOptional(G,U,"batchingIdTexture"),Ge.setValue(G,"batchingIdTexture",U._indirectTexture,$e),Ge.setOptional(G,U,"batchingColorTexture"),U._colorsTexture!==null&&Ge.setValue(G,"batchingColorTexture",U._colorsTexture,$e));let jt=z.morphAttributes;if((jt.position!==void 0||jt.normal!==void 0||jt.color!==void 0)&&Re.update(U,z,lt),(st||Te.receiveShadow!==U.receiveShadow)&&(Te.receiveShadow=U.receiveShadow,Ge.setValue(G,"receiveShadow",U.receiveShadow)),R.isMeshGouraudMaterial&&R.envMap!==null&&(Nt.envMap.value=Q,Nt.flipEnvMap.value=Q.isCubeTexture&&Q.isRenderTargetTexture===!1?-1:1),R.isMeshStandardMaterial&&R.envMap===null&&F.environment!==null&&(Nt.envMapIntensity.value=F.environmentIntensity),Nt.dfgLUT!==void 0&&(Nt.dfgLUT.value=z_()),st&&(Ge.setValue(G,"toneMappingExposure",A.toneMappingExposure),Te.needsLights&&ri(Nt,it),W&&R.fog===!0&&Fe.refreshFogUniforms(Nt,W),Fe.refreshMaterialUniforms(Nt,R,ce,le,y.state.transmissionRenderTarget[v.id]),ts.upload(G,As(Te),Nt,$e)),R.isShaderMaterial&&R.uniformsNeedUpdate===!0&&(ts.upload(G,As(Te),Nt,$e),R.uniformsNeedUpdate=!1),R.isSpriteMaterial&&Ge.setValue(G,"center",U.center),Ge.setValue(G,"modelViewMatrix",U.modelViewMatrix),Ge.setValue(G,"normalMatrix",U.normalMatrix),Ge.setValue(G,"modelMatrix",U.matrixWorld),R.isShaderMaterial||R.isRawShaderMaterial){let Pt=R.uniformsGroups;for(let qt=0,Fl=Pt.length;qt<Fl;qt++){let Yi=Pt[qt];_e.update(Yi,lt),_e.bind(Yi,lt)}}return lt}function ri(v,F){v.ambientLightColor.needsUpdate=F,v.lightProbe.needsUpdate=F,v.directionalLights.needsUpdate=F,v.directionalLightShadows.needsUpdate=F,v.pointLights.needsUpdate=F,v.pointLightShadows.needsUpdate=F,v.spotLights.needsUpdate=F,v.spotLightShadows.needsUpdate=F,v.rectAreaLights.needsUpdate=F,v.hemisphereLights.needsUpdate=F}function Qn(v){return v.isMeshLambertMaterial||v.isMeshToonMaterial||v.isMeshPhongMaterial||v.isMeshStandardMaterial||v.isShadowMaterial||v.isShaderMaterial&&v.lights===!0}this.getActiveCubeFace=function(){return D},this.getActiveMipmapLevel=function(){return T},this.getRenderTarget=function(){return S},this.setRenderTargetTextures=function(v,F,z){let R=Be.get(v);R.__autoAllocateDepthBuffer=v.resolveDepthBuffer===!1,R.__autoAllocateDepthBuffer===!1&&(R.__useRenderToTexture=!1),Be.get(v.texture).__webglTexture=F,Be.get(v.depthTexture).__webglTexture=R.__autoAllocateDepthBuffer?void 0:z,R.__hasExternalTextures=!0},this.setRenderTargetFramebuffer=function(v,F){let z=Be.get(v);z.__webglFramebuffer=F,z.__useDefaultFramebuffer=F===void 0};let x=G.createFramebuffer();this.setRenderTarget=function(v,F=0,z=0){S=v,D=F,T=z;let R=!0,U=null,W=!1,X=!1;if(v){let Q=Be.get(v);if(Q.__useDefaultFramebuffer!==void 0)Ae.bindFramebuffer(G.FRAMEBUFFER,null),R=!1;else if(Q.__webglFramebuffer===void 0)$e.setupRenderTarget(v);else if(Q.__hasExternalTextures)$e.rebindTextures(v,Be.get(v.texture).__webglTexture,Be.get(v.depthTexture).__webglTexture);else if(v.depthBuffer){let ae=v.depthTexture;if(Q.__boundDepthTexture!==ae){if(ae!==null&&Be.has(ae)&&(v.width!==ae.image.width||v.height!==ae.image.height))throw new Error("WebGLRenderTarget: Attached DepthTexture is initialized to the incorrect size.");$e.setupDepthRenderbuffer(v)}}let ee=v.texture;(ee.isData3DTexture||ee.isDataArrayTexture||ee.isCompressedArrayTexture)&&(X=!0);let ne=Be.get(v).__webglFramebuffer;v.isWebGLCubeRenderTarget?(Array.isArray(ne[F])?U=ne[F][z]:U=ne[F],W=!0):v.samples>0&&$e.useMultisampledRTT(v)===!1?U=Be.get(v).__webglMultisampledFramebuffer:Array.isArray(ne)?U=ne[z]:U=ne,O.copy(v.viewport),H.copy(v.scissor),q=v.scissorTest}else O.copy(ke).multiplyScalar(ce).floor(),H.copy(ct).multiplyScalar(ce).floor(),q=nt;if(z!==0&&(U=x),Ae.bindFramebuffer(G.FRAMEBUFFER,U)&&R&&Ae.drawBuffers(v,U),Ae.viewport(O),Ae.scissor(H),Ae.setScissorTest(q),W){let Q=Be.get(v.texture);G.framebufferTexture2D(G.FRAMEBUFFER,G.COLOR_ATTACHMENT0,G.TEXTURE_CUBE_MAP_POSITIVE_X+F,Q.__webglTexture,z)}else if(X){let Q=F;for(let ee=0;ee<v.textures.length;ee++){let ne=Be.get(v.textures[ee]);G.framebufferTextureLayer(G.FRAMEBUFFER,G.COLOR_ATTACHMENT0+ee,ne.__webglTexture,z,Q)}}else if(v!==null&&z!==0){let Q=Be.get(v.texture);G.framebufferTexture2D(G.FRAMEBUFFER,G.COLOR_ATTACHMENT0,G.TEXTURE_2D,Q.__webglTexture,z)}P=-1},this.readRenderTargetPixels=function(v,F,z,R,U,W,X,Z=0){if(!(v&&v.isWebGLRenderTarget)){ut("WebGLRenderer.readRenderTargetPixels: renderTarget is not THREE.WebGLRenderTarget.");return}let Q=Be.get(v).__webglFramebuffer;if(v.isWebGLCubeRenderTarget&&X!==void 0&&(Q=Q[X]),Q){Ae.bindFramebuffer(G.FRAMEBUFFER,Q);try{let ee=v.textures[Z],ne=ee.format,ae=ee.type;if(!yt.textureFormatReadable(ne)){ut("WebGLRenderer.readRenderTargetPixels: renderTarget is not in RGBA or implementation defined format.");return}if(!yt.textureTypeReadable(ae)){ut("WebGLRenderer.readRenderTargetPixels: renderTarget is not in UnsignedByteType or implementation defined type.");return}F>=0&&F<=v.width-R&&z>=0&&z<=v.height-U&&(v.textures.length>1&&G.readBuffer(G.COLOR_ATTACHMENT0+Z),G.readPixels(F,z,R,U,Ie.convert(ne),Ie.convert(ae),W))}finally{let ee=S!==null?Be.get(S).__webglFramebuffer:null;Ae.bindFramebuffer(G.FRAMEBUFFER,ee)}}},this.readRenderTargetPixelsAsync=async function(v,F,z,R,U,W,X,Z=0){if(!(v&&v.isWebGLRenderTarget))throw new Error("THREE.WebGLRenderer.readRenderTargetPixels: renderTarget is not THREE.WebGLRenderTarget.");let Q=Be.get(v).__webglFramebuffer;if(v.isWebGLCubeRenderTarget&&X!==void 0&&(Q=Q[X]),Q)if(F>=0&&F<=v.width-R&&z>=0&&z<=v.height-U){Ae.bindFramebuffer(G.FRAMEBUFFER,Q);let ee=v.textures[Z],ne=ee.format,ae=ee.type;if(!yt.textureFormatReadable(ne))throw new Error("THREE.WebGLRenderer.readRenderTargetPixelsAsync: renderTarget is not in RGBA or implementation defined format.");if(!yt.textureTypeReadable(ae))throw new Error("THREE.WebGLRenderer.readRenderTargetPixelsAsync: renderTarget is not in UnsignedByteType or implementation defined type.");let oe=G.createBuffer();G.bindBuffer(G.PIXEL_PACK_BUFFER,oe),G.bufferData(G.PIXEL_PACK_BUFFER,W.byteLength,G.STREAM_READ),v.textures.length>1&&G.readBuffer(G.COLOR_ATTACHMENT0+Z),G.readPixels(F,z,R,U,Ie.convert(ne),Ie.convert(ae),0);let pe=S!==null?Be.get(S).__webglFramebuffer:null;Ae.bindFramebuffer(G.FRAMEBUFFER,pe);let Me=G.fenceSync(G.SYNC_GPU_COMMANDS_COMPLETE,0);return G.flush(),await qf(G,Me,4),G.bindBuffer(G.PIXEL_PACK_BUFFER,oe),G.getBufferSubData(G.PIXEL_PACK_BUFFER,0,W),G.deleteBuffer(oe),G.deleteSync(Me),W}else throw new Error("THREE.WebGLRenderer.readRenderTargetPixelsAsync: requested read bounds are out of range.")},this.copyFramebufferToTexture=function(v,F=null,z=0){let R=Math.pow(2,-z),U=Math.floor(v.image.width*R),W=Math.floor(v.image.height*R),X=F!==null?F.x:0,Z=F!==null?F.y:0;$e.setTexture2D(v,0),G.copyTexSubImage2D(G.TEXTURE_2D,z,0,0,X,Z,U,W),Ae.unbindTexture()};let C=G.createFramebuffer(),B=G.createFramebuffer();this.copyTextureToTexture=function(v,F,z=null,R=null,U=0,W=null){W===null&&(U!==0?(Gr("WebGLRenderer: copyTextureToTexture function signature has changed to support src and dst mipmap levels."),W=U,U=0):W=0);let X,Z,Q,ee,ne,ae,oe,pe,Me,Ne=v.isCompressedTexture?v.mipmaps[W]:v.image;if(z!==null)X=z.max.x-z.min.x,Z=z.max.y-z.min.y,Q=z.isBox3?z.max.z-z.min.z:1,ee=z.min.x,ne=z.min.y,ae=z.isBox3?z.min.z:0;else{let jt=Math.pow(2,-U);X=Math.floor(Ne.width*jt),Z=Math.floor(Ne.height*jt),v.isDataArrayTexture?Q=Ne.depth:v.isData3DTexture?Q=Math.floor(Ne.depth*jt):Q=1,ee=0,ne=0,ae=0}R!==null?(oe=R.x,pe=R.y,Me=R.z):(oe=0,pe=0,Me=0);let Ue=Ie.convert(F.format),Te=Ie.convert(F.type),Ve;F.isData3DTexture?($e.setTexture3D(F,0),Ve=G.TEXTURE_3D):F.isDataArrayTexture||F.isCompressedArrayTexture?($e.setTexture2DArray(F,0),Ve=G.TEXTURE_2D_ARRAY):($e.setTexture2D(F,0),Ve=G.TEXTURE_2D),G.pixelStorei(G.UNPACK_FLIP_Y_WEBGL,F.flipY),G.pixelStorei(G.UNPACK_PREMULTIPLY_ALPHA_WEBGL,F.premultiplyAlpha),G.pixelStorei(G.UNPACK_ALIGNMENT,F.unpackAlignment);let ye=G.getParameter(G.UNPACK_ROW_LENGTH),lt=G.getParameter(G.UNPACK_IMAGE_HEIGHT),Dt=G.getParameter(G.UNPACK_SKIP_PIXELS),st=G.getParameter(G.UNPACK_SKIP_ROWS),it=G.getParameter(G.UNPACK_SKIP_IMAGES);G.pixelStorei(G.UNPACK_ROW_LENGTH,Ne.width),G.pixelStorei(G.UNPACK_IMAGE_HEIGHT,Ne.height),G.pixelStorei(G.UNPACK_SKIP_PIXELS,ee),G.pixelStorei(G.UNPACK_SKIP_ROWS,ne),G.pixelStorei(G.UNPACK_SKIP_IMAGES,ae);let Ge=v.isDataArrayTexture||v.isData3DTexture,Nt=F.isDataArrayTexture||F.isData3DTexture;if(v.isDepthTexture){let jt=Be.get(v),Pt=Be.get(F),qt=Be.get(jt.__renderTarget),Fl=Be.get(Pt.__renderTarget);Ae.bindFramebuffer(G.READ_FRAMEBUFFER,qt.__webglFramebuffer),Ae.bindFramebuffer(G.DRAW_FRAMEBUFFER,Fl.__webglFramebuffer);for(let Yi=0;Yi<Q;Yi++)Ge&&(G.framebufferTextureLayer(G.READ_FRAMEBUFFER,G.COLOR_ATTACHMENT0,Be.get(v).__webglTexture,U,ae+Yi),G.framebufferTextureLayer(G.DRAW_FRAMEBUFFER,G.COLOR_ATTACHMENT0,Be.get(F).__webglTexture,W,Me+Yi)),G.blitFramebuffer(ee,ne,X,Z,oe,pe,X,Z,G.DEPTH_BUFFER_BIT,G.NEAREST);Ae.bindFramebuffer(G.READ_FRAMEBUFFER,null),Ae.bindFramebuffer(G.DRAW_FRAMEBUFFER,null)}else if(U!==0||v.isRenderTargetTexture||Be.has(v)){let jt=Be.get(v),Pt=Be.get(F);Ae.bindFramebuffer(G.READ_FRAMEBUFFER,C),Ae.bindFramebuffer(G.DRAW_FRAMEBUFFER,B);for(let qt=0;qt<Q;qt++)Ge?G.framebufferTextureLayer(G.READ_FRAMEBUFFER,G.COLOR_ATTACHMENT0,jt.__webglTexture,U,ae+qt):G.framebufferTexture2D(G.READ_FRAMEBUFFER,G.COLOR_ATTACHMENT0,G.TEXTURE_2D,jt.__webglTexture,U),Nt?G.framebufferTextureLayer(G.DRAW_FRAMEBUFFER,G.COLOR_ATTACHMENT0,Pt.__webglTexture,W,Me+qt):G.framebufferTexture2D(G.DRAW_FRAMEBUFFER,G.COLOR_ATTACHMENT0,G.TEXTURE_2D,Pt.__webglTexture,W),U!==0?G.blitFramebuffer(ee,ne,X,Z,oe,pe,X,Z,G.COLOR_BUFFER_BIT,G.NEAREST):Nt?G.copyTexSubImage3D(Ve,W,oe,pe,Me+qt,ee,ne,X,Z):G.copyTexSubImage2D(Ve,W,oe,pe,ee,ne,X,Z);Ae.bindFramebuffer(G.READ_FRAMEBUFFER,null),Ae.bindFramebuffer(G.DRAW_FRAMEBUFFER,null)}else Nt?v.isDataTexture||v.isData3DTexture?G.texSubImage3D(Ve,W,oe,pe,Me,X,Z,Q,Ue,Te,Ne.data):F.isCompressedArrayTexture?G.compressedTexSubImage3D(Ve,W,oe,pe,Me,X,Z,Q,Ue,Ne.data):G.texSubImage3D(Ve,W,oe,pe,Me,X,Z,Q,Ue,Te,Ne):v.isDataTexture?G.texSubImage2D(G.TEXTURE_2D,W,oe,pe,X,Z,Ue,Te,Ne.data):v.isCompressedTexture?G.compressedTexSubImage2D(G.TEXTURE_2D,W,oe,pe,Ne.width,Ne.height,Ue,Ne.data):G.texSubImage2D(G.TEXTURE_2D,W,oe,pe,X,Z,Ue,Te,Ne);G.pixelStorei(G.UNPACK_ROW_LENGTH,ye),G.pixelStorei(G.UNPACK_IMAGE_HEIGHT,lt),G.pixelStorei(G.UNPACK_SKIP_PIXELS,Dt),G.pixelStorei(G.UNPACK_SKIP_ROWS,st),G.pixelStorei(G.UNPACK_SKIP_IMAGES,it),W===0&&F.generateMipmaps&&G.generateMipmap(Ve),Ae.unbindTexture()},this.initRenderTarget=function(v){Be.get(v).__webglFramebuffer===void 0&&$e.setupRenderTarget(v)},this.initTexture=function(v){v.isCubeTexture?$e.setTextureCube(v,0):v.isData3DTexture?$e.setTexture3D(v,0):v.isDataArrayTexture||v.isCompressedArrayTexture?$e.setTexture2DArray(v,0):$e.setTexture2D(v,0),Ae.unbindTexture()},this.resetState=function(){D=0,T=0,S=null,Ae.reset(),V.reset()},typeof __THREE_DEVTOOLS__<"u"&&__THREE_DEVTOOLS__.dispatchEvent(new CustomEvent("observe",{detail:this}))}get coordinateSystem(){return Hn}get outputColorSpace(){return this._outputColorSpace}set outputColorSpace(e){this._outputColorSpace=e;let t=this.getContext();t.drawingBufferColorSpace=dt._getDrawingBufferColorSpace(e),t.unpackColorSpace=dt._getUnpackColorSpace()}};var Md=Math.pow(2,-24),fa=Symbol("SKIP_GENERATION"),_c={strategy:0,maxDepth:40,maxLeafSize:10,useSharedArrayBuffer:!1,setBoundingBox:!0,onProgress:null,indirect:!1,verbose:!0,range:null,[fa]:!1};function Et(i,e,t){return t.min.x=e[i],t.min.y=e[i+1],t.min.z=e[i+2],t.max.x=e[i+3],t.max.y=e[i+4],t.max.z=e[i+5],t}function $u(i){let e=-1,t=-1/0;for(let n=0;n<3;n++){let r=i[n+3]-i[n];r>t&&(t=r,e=n)}return e}function Ju(i,e){e.set(i)}function Ku(i,e,t){let n,r;for(let s=0;s<3;s++){let a=s+3;n=i[s],r=e[s],t[s]=n<r?n:r,n=i[a],r=e[a],t[a]=n>r?n:r}}function da(i,e,t){for(let n=0;n<3;n++){let r=e[i+2*n],s=e[i+2*n+1],a=r-s,o=r+s;a<t[n]&&(t[n]=a),o>t[n+3]&&(t[n+3]=o)}}function is(i){let e=i[3]-i[0],t=i[4]-i[1],n=i[5]-i[2];return 2*(e*t+t*n+n*e)}function gt(i,e){return e[i+15]===65535}function zt(i,e){return e[i+6]}function Vt(i,e){return e[i+14]}function Mt(i){return i+8}function Tt(i,e){let t=e[i+6];return i+t*8}function zi(i,e){return e[i+7]}function yc(i,e,t,n,r){let s=1/0,a=1/0,o=1/0,c=-1/0,u=-1/0,f=-1/0,h=1/0,l=1/0,p=1/0,g=-1/0,b=-1/0,m=-1/0,d=i.offset||0;for(let _=(e-d)*6,y=(e+t-d)*6;_<y;_+=6){let M=i[_+0],w=i[_+1],A=M-w,I=M+w;A<s&&(s=A),I>c&&(c=I),M<h&&(h=M),M>g&&(g=M);let D=i[_+2],T=i[_+3],S=D-T,P=D+T;S<a&&(a=S),P>u&&(u=P),D<l&&(l=D),D>b&&(b=D);let L=i[_+4],O=i[_+5],H=L-O,q=L+O;H<o&&(o=H),q>f&&(f=q),L<p&&(p=L),L>m&&(m=L)}n[0]=s,n[1]=a,n[2]=o,n[3]=c,n[4]=u,n[5]=f,r[0]=h,r[1]=l,r[2]=p,r[3]=g,r[4]=b,r[5]=m}var vi=32,G_=(i,e)=>i.candidate-e.candidate,ki=new Array(vi).fill().map(()=>({count:0,bounds:new Float32Array(6),rightCacheBounds:new Float32Array(6),leftCacheBounds:new Float32Array(6),candidate:0})),bc=new Float32Array(6);function Ad(i,e,t,n,r,s){let a=-1,o=0;if(s===0)a=$u(e),a!==-1&&(o=(e[a]+e[a+3])/2);else if(s===1)a=$u(i),a!==-1&&(o=W_(t,n,r,a));else if(s===2){let c=is(i),u=1.25*r,f=t.offset||0,h=(n-f)*6,l=(n+r-f)*6;for(let p=0;p<3;p++){let g=e[p],d=(e[p+3]-g)/vi;if(r<vi/4){let _=[...ki];_.length=r;let y=0;for(let w=h;w<l;w+=6,y++){let A=_[y];A.candidate=t[w+2*p],A.count=0;let{bounds:I,leftCacheBounds:D,rightCacheBounds:T}=A;for(let S=0;S<3;S++)T[S]=1/0,T[S+3]=-1/0,D[S]=1/0,D[S+3]=-1/0,I[S]=1/0,I[S+3]=-1/0;da(w,t,I)}_.sort(G_);let M=r;for(let w=0;w<M;w++){let A=_[w];for(;w+1<M&&_[w+1].candidate===A.candidate;)_.splice(w+1,1),M--}for(let w=h;w<l;w+=6){let A=t[w+2*p];for(let I=0;I<M;I++){let D=_[I];A>=D.candidate?da(w,t,D.rightCacheBounds):(da(w,t,D.leftCacheBounds),D.count++)}}for(let w=0;w<M;w++){let A=_[w],I=A.count,D=r-A.count,T=A.leftCacheBounds,S=A.rightCacheBounds,P=0;I!==0&&(P=is(T)/c);let L=0;D!==0&&(L=is(S)/c);let O=1+1.25*(P*I+L*D);O<u&&(a=p,u=O,o=A.candidate)}}else{for(let M=0;M<vi;M++){let w=ki[M];w.count=0,w.candidate=g+d+M*d;let A=w.bounds;for(let I=0;I<3;I++)A[I]=1/0,A[I+3]=-1/0}for(let M=h;M<l;M+=6){let I=~~((t[M+2*p]-g)/d);I>=vi&&(I=vi-1);let D=ki[I];D.count++,da(M,t,D.bounds)}let _=ki[vi-1];Ju(_.bounds,_.rightCacheBounds);for(let M=vi-2;M>=0;M--){let w=ki[M],A=ki[M+1];Ku(w.bounds,A.rightCacheBounds,w.rightCacheBounds)}let y=0;for(let M=0;M<vi-1;M++){let w=ki[M],A=w.count,I=w.bounds,T=ki[M+1].rightCacheBounds;A!==0&&(y===0?Ju(I,bc):Ku(I,bc,bc)),y+=A;let S=0,P=0;y!==0&&(S=is(bc)/c);let L=r-y;L!==0&&(P=is(T)/c);let O=1+1.25*(S*y+P*L);O<u&&(a=p,u=O,o=w.candidate)}}}}else console.warn(`BVH: Invalid build strategy value ${s} used.`);return{axis:a,pos:o}}function W_(i,e,t,n){let r=0,s=i.offset;for(let a=e,o=e+t;a<o;a++)r+=i[(a-s)*6+n*2];return r/t}var rs=class{constructor(){this.boundingData=new Float32Array(6)}};function Ed(i,e,t,n,r,s){let a=n,o=n+r-1,c=s.pos,u=s.axis*2,f=t.offset||0;for(;;){for(;a<=o&&t[(a-f)*6+u]<c;)a++;for(;a<=o&&t[(o-f)*6+u]>=c;)o--;if(a<o){for(let h=0;h<e;h++){let l=i[a*e+h];i[a*e+h]=i[o*e+h],i[o*e+h]=l}for(let h=0;h<6;h++){let l=a-f,p=o-f,g=t[l*6+h];t[l*6+h]=t[p*6+h],t[p*6+h]=g}a++,o--}else return a}}var Cd,Sc,Qu,Rd,X_=Math.pow(2,32);function Mc(i){return"count"in i?1:1+Mc(i.left)+Mc(i.right)}function Id(i,e,t){return Cd=new Float32Array(t),Sc=new Uint32Array(t),Qu=new Uint16Array(t),Rd=new Uint8Array(t),ju(i,e)}function ju(i,e){let t=i/4,n=i/2,r="count"in e,s=e.boundingData;for(let a=0;a<6;a++)Cd[t+a]=s[a];if(r)return e.buffer?(Rd.set(new Uint8Array(e.buffer),i),i+e.buffer.byteLength):(Sc[t+6]=e.offset,Qu[n+14]=e.count,Qu[n+15]=65535,i+32);{let{left:a,right:o,splitAxis:c}=e,u=i+32,f=ju(u,a),h=i/32,p=f/32-h;if(p>X_)throw new Error("MeshBVH: Cannot store relative child node offset greater than 32 bits.");return Sc[t+6]=p,Sc[t+7]=c,ju(f,o)}}function q_(i,e,t,n,r){let{maxDepth:s,verbose:a,maxLeafSize:o,strategy:c,onProgress:u}=r,f=i.primitiveBuffer,h=i.primitiveBufferStride,l=new Float32Array(6),p=!1,g=new rs;return yc(e,t,n,g.boundingData,l),m(g,t,n,l),g;function b(d){u&&u(d/n)}function m(d,_,y,M=null,w=0){if(!p&&w>=s&&(p=!0,a&&console.warn(`BVH: Max depth of ${s} reached when generating BVH. Consider increasing maxDepth.`)),y<=o||w>=s)return b(_+y),d.offset=_,d.count=y,d;let A=Ad(d.boundingData,M,e,_,y,c);if(A.axis===-1)return b(_+y),d.offset=_,d.count=y,d;let I=Ed(f,h,e,_,y,A);if(I===_||I===_+y)b(_+y),d.offset=_,d.count=y;else{d.splitAxis=A.axis;let D=new rs,T=_,S=I-_;d.left=D,yc(e,T,S,D.boundingData,l),m(D,T,S,l,w+1);let P=new rs,L=I,O=y-S;d.right=P,yc(e,L,O,P.boundingData,l),m(P,L,O,l,w+1)}return d}}function Pd(i,e){let t=e.useSharedArrayBuffer?SharedArrayBuffer:ArrayBuffer,n=i.getRootRanges(e.range),r=n[0],s=n[n.length-1],a={offset:r.offset,count:s.offset+s.count-r.offset},o=new Float32Array(6*a.count);o.offset=a.offset,i.computePrimitiveBounds(a.offset,a.count,o),i._roots=n.map(c=>{let u=q_(i,o,c.offset,c.count,e),f=Mc(u),h=new t(32*f);return Id(0,u,h),h})}var Vi=class{constructor(e){this._getNewPrimitive=e,this._primitives=[]}getPrimitive(){let e=this._primitives;return e.length===0?this._getNewPrimitive():e.pop()}releasePrimitive(e){this._primitives.push(e)}};var eh=class{constructor(){this.float32Array=null,this.uint16Array=null,this.uint32Array=null;let e=[],t=null;this.setBuffer=n=>{t&&e.push(t),t=n,this.float32Array=new Float32Array(n),this.uint16Array=new Uint16Array(n),this.uint32Array=new Uint32Array(n)},this.clearBuffer=()=>{t=null,this.float32Array=null,this.uint16Array=null,this.uint32Array=null,e.length!==0&&this.setBuffer(e.pop())}}},pt=new eh;var Hi,as,ss=[],Tc=new Vi(()=>new Ut);function Dd(i,e,t,n,r,s){Hi=Tc.getPrimitive(),as=Tc.getPrimitive(),ss.push(Hi,as),pt.setBuffer(i._roots[e]);let a=th(0,i.geometry,t,n,r,s);pt.clearBuffer(),Tc.releasePrimitive(Hi),Tc.releasePrimitive(as),ss.pop(),ss.pop();let o=ss.length;return o>0&&(as=ss[o-1],Hi=ss[o-2]),a}function th(i,e,t,n,r=null,s=0,a=0){let{float32Array:o,uint16Array:c,uint32Array:u}=pt,f=i*2;if(gt(f,c)){let l=zt(i,u),p=Vt(f,c);return Et(i,o,Hi),n(l,p,!1,a,s+i/8,Hi)}else{let S=function(L){let{uint16Array:O,uint32Array:H}=pt,q=L*2;for(;!gt(q,O);)L=Mt(L),q=L*2;return zt(L,H)},P=function(L){let{uint16Array:O,uint32Array:H}=pt,q=L*2;for(;!gt(q,O);)L=Tt(L,H),q=L*2;return zt(L,H)+Vt(q,O)},l=Mt(i),p=Tt(i,u),g=l,b=p,m,d,_,y;if(r&&(_=Hi,y=as,Et(g,o,_),Et(b,o,y),m=r(_),d=r(y),d<m)){g=p,b=l;let L=m;m=d,d=L,_=y}_||(_=Hi,Et(g,o,_));let M=gt(g*2,c),w=t(_,M,m,a+1,s+g/8),A;if(w===2){let L=S(g),H=P(g)-L;A=n(L,H,!0,a+1,s+g/8,_)}else A=w&&th(g,e,t,n,r,s,a+1);if(A)return!0;y=as,Et(b,o,y);let I=gt(b*2,c),D=t(y,I,d,a+1,s+b/8),T;if(D===2){let L=S(b),H=P(b)-L;T=n(L,H,!0,a+1,s+b/8,y)}else T=D&&th(b,e,t,n,r,s,a+1);return!!T}}function pa(i){return i.index?i.index.count:i.attributes.position.count}function Gi(i){return pa(i)/3}function nh(i,e=ArrayBuffer){return i>65535?new Uint32Array(new e(4*i)):new Uint16Array(new e(2*i))}function Fd(i,e){if(!i.index){let t=i.attributes.position.count,n=e.useSharedArrayBuffer?SharedArrayBuffer:ArrayBuffer,r=nh(t,n);i.setIndex(new mt(r,1));for(let s=0;s<t;s++)r[s]=s}}function Z_(i,e,t){let n=pa(i)/t,r=e||i.drawRange,s=r.start/t,a=(r.start+r.count)/t,o=Math.max(0,s),c=Math.min(n,a)-o;return{offset:Math.floor(o),count:Math.floor(c)}}function $_(i,e){return i.groups.map(t=>({offset:t.start/e,count:t.count/e}))}function ma(i,e,t){let n=Z_(i,e,t),r=$_(i,t);if(!r.length)return[n];let s=[],a=n.offset,o=n.offset+n.count,c=pa(i)/t,u=[];for(let l of r){let{offset:p,count:g}=l,b=p,m=isFinite(g)?g:c-p,d=p+m;b<o&&d>a&&(u.push({pos:Math.max(a,b),isStart:!0}),u.push({pos:Math.min(o,d),isStart:!1}))}u.sort((l,p)=>l.pos!==p.pos?l.pos-p.pos:l.type==="end"?-1:1);let f=0,h=null;for(let l of u){let p=l.pos;f!==0&&p!==h&&s.push({offset:h,count:p-h}),f+=l.isStart?1:-1,h=p}return s}var Ld=new Ut,Ac=class{constructor(){this._roots=null,this.primitiveBuffer=null,this.primitiveBufferStride=null}init(e){e={..._c,...e},Pd(this,e)}getRootRanges(e){return ma(this.geometry,e,this.primitiveStride)}raycastObject3D(){throw new Error("BVH: raycastObject3D() not implemented")}shiftPrimitiveOffsets(e){let t=this._indirectBuffer;if(t)for(let n=0,r=t.length;n<r;n++)t[n]+=e;else{let n=this._roots;for(let r=0;r<n.length;r++){let s=n[r],a=new Uint32Array(s),o=new Uint16Array(s),c=s.byteLength/32;for(let u=0;u<c;u++){let f=8*u,h=2*f;gt(h,o)&&(a[f+6]+=e)}}}}traverse(e,t=0){let n=this._roots[t],r=new Uint32Array(n),s=new Uint16Array(n);a(0);function a(o,c=0){let u=o*2,f=gt(u,s);if(f){let h=r[o+6],l=s[u+14];e(c,f,new Float32Array(n,o*4,6),h,l)}else{let h=Mt(o),l=Tt(o,r),p=zi(o,r);e(c,f,new Float32Array(n,o*4,6),p)||(a(h,c+1),a(l,c+1))}}}getBoundingBox(e){return e.makeEmpty(),this._roots.forEach(n=>{Et(0,new Float32Array(n),Ld),e.union(Ld)}),e}shapecast(e){let{boundsTraverseOrder:t,intersectsBounds:n,intersectsRange:r,intersectsPrimitive:s,scratchPrimitive:a,iterate:o}=e;if(r&&s){let h=r;r=(l,p,g,b,m)=>h(l,p,g,b,m)?!0:o(l,p,this,s,g,b,a)}else r||(s?r=(h,l,p,g)=>o(h,l,this,s,p,g,a):r=(h,l,p)=>p);let c=!1,u=0,f=this._roots;for(let h=0,l=f.length;h<l;h++){let p=f[h];if(c=Dd(this,h,n,r,t,u),c)break;u+=p.byteLength/32}return c}};var In=class{constructor(){this.min=1/0,this.max=-1/0}setFromPointsField(e,t){let n=1/0,r=-1/0;for(let s=0,a=e.length;s<a;s++){let c=e[s][t];n=c<n?c:n,r=c>r?c:r}this.min=n,this.max=r}setFromPoints(e,t){let n=1/0,r=-1/0;for(let s=0,a=t.length;s<a;s++){let o=t[s],c=e.dot(o);n=c<n?c:n,r=c>r?c:r}this.min=n,this.max=r}isSeparated(e){return this.min>e.max||e.min>this.max}};In.prototype.setFromBox=(function(){let i=new k;return function(t,n){let r=n.min,s=n.max,a=1/0,o=-1/0;for(let c=0;c<=1;c++)for(let u=0;u<=1;u++)for(let f=0;f<=1;f++){i.x=r.x*c+s.x*(1-c),i.y=r.y*u+s.y*(1-u),i.z=r.z*f+s.z*(1-f);let h=t.dot(i);a=Math.min(h,a),o=Math.max(h,o)}this.min=a,this.max=o}})();var J_=(function(){let i=new k,e=new k,t=new k;return function(r,s,a){let o=r.start,c=i,u=s.start,f=e;t.subVectors(o,u),i.subVectors(r.end,r.start),e.subVectors(s.end,s.start);let h=t.dot(f),l=f.dot(c),p=f.dot(f),g=t.dot(c),m=c.dot(c)*p-l*l,d,_;m!==0?d=(h*l-g*p)/m:d=0,_=(h+d*l)/p,a.x=d,a.y=_}})(),ga=(function(){let i=new Le,e=new k,t=new k;return function(r,s,a,o){J_(r,s,i);let c=i.x,u=i.y;if(c>=0&&c<=1&&u>=0&&u<=1){r.at(c,a),s.at(u,o);return}else if(c>=0&&c<=1){u<0?s.at(0,o):s.at(1,o),r.closestPointToPoint(o,!0,a);return}else if(u>=0&&u<=1){c<0?r.at(0,a):r.at(1,a),s.closestPointToPoint(a,!0,o);return}else{let f;c<0?f=r.start:f=r.end;let h;u<0?h=s.start:h=s.end;let l=e,p=t;if(r.closestPointToPoint(h,!0,e),s.closestPointToPoint(f,!0,t),l.distanceToSquared(h)<=p.distanceToSquared(f)){a.copy(l),o.copy(h);return}else{a.copy(f),o.copy(p);return}}}})(),Nd=(function(){let i=new k,e=new k,t=new Sn,n=new gn;return function(s,a){let{radius:o,center:c}=s,{a:u,b:f,c:h}=a;if(n.start=u,n.end=f,n.closestPointToPoint(c,!0,i).distanceTo(c)<=o||(n.start=u,n.end=h,n.closestPointToPoint(c,!0,i).distanceTo(c)<=o)||(n.start=f,n.end=h,n.closestPointToPoint(c,!0,i).distanceTo(c)<=o))return!0;let b=a.getPlane(t);if(Math.abs(b.distanceToPoint(c))<=o){let d=b.projectPoint(c,e);if(a.containsPoint(d))return!0}return!1}})();var K_=["x","y","z"],_i=1e-15,Ud=_i*_i;function Nn(i){return Math.abs(i)<_i}var an=class extends un{constructor(...e){super(...e),this.isExtendedTriangle=!0,this.satAxes=new Array(4).fill().map(()=>new k),this.satBounds=new Array(4).fill().map(()=>new In),this.points=[this.a,this.b,this.c],this.plane=new Sn,this.isDegenerateIntoSegment=!1,this.isDegenerateIntoPoint=!1,this.degenerateSegment=new gn,this.needsUpdate=!0}intersectsSphere(e){return Nd(e,this)}update(){let e=this.a,t=this.b,n=this.c,r=this.points,s=this.satAxes,a=this.satBounds,o=s[0],c=a[0];this.getNormal(o),c.setFromPoints(o,r);let u=s[1],f=a[1];u.subVectors(e,t),f.setFromPoints(u,r);let h=s[2],l=a[2];h.subVectors(t,n),l.setFromPoints(h,r);let p=s[3],g=a[3];p.subVectors(n,e),g.setFromPoints(p,r);let b=u.length(),m=h.length(),d=p.length();this.isDegenerateIntoPoint=!1,this.isDegenerateIntoSegment=!1,b<_i?m<_i||d<_i?this.isDegenerateIntoPoint=!0:(this.isDegenerateIntoSegment=!0,this.degenerateSegment.start.copy(e),this.degenerateSegment.end.copy(n)):m<_i?d<_i?this.isDegenerateIntoPoint=!0:(this.isDegenerateIntoSegment=!0,this.degenerateSegment.start.copy(t),this.degenerateSegment.end.copy(e)):d<_i&&(this.isDegenerateIntoSegment=!0,this.degenerateSegment.start.copy(n),this.degenerateSegment.end.copy(t)),this.plane.setFromNormalAndCoplanarPoint(o,e),this.needsUpdate=!1}};an.prototype.closestPointToSegment=(function(){let i=new k,e=new k,t=new gn;return function(r,s=null,a=null){let{start:o,end:c}=r,u=this.points,f,h=1/0;for(let l=0;l<3;l++){let p=(l+1)%3;t.start.copy(u[l]),t.end.copy(u[p]),ga(t,r,i,e),f=i.distanceToSquared(e),f<h&&(h=f,s&&s.copy(i),a&&a.copy(e))}return this.closestPointToPoint(o,i),f=o.distanceToSquared(i),f<h&&(h=f,s&&s.copy(i),a&&a.copy(o)),this.closestPointToPoint(c,i),f=c.distanceToSquared(i),f<h&&(h=f,s&&s.copy(i),a&&a.copy(c)),Math.sqrt(h)}})();an.prototype.intersectsTriangle=(function(){let i=new an,e=new In,t=new In,n=new k,r=new k,s=new k,a=new k,o=new gn,c=new gn,u=new k,f=new Le,h=new Le;function l(y,M,w,A){let I=n;!y.isDegenerateIntoPoint&&!y.isDegenerateIntoSegment?I.copy(y.plane.normal):I.copy(M.plane.normal);let D=y.satBounds,T=y.satAxes;for(let L=1;L<4;L++){let O=D[L],H=T[L];if(e.setFromPoints(H,M.points),O.isSeparated(e)||(a.copy(I).cross(H),e.setFromPoints(a,y.points),t.setFromPoints(a,M.points),e.isSeparated(t)))return!1}let S=M.satBounds,P=M.satAxes;for(let L=1;L<4;L++){let O=S[L],H=P[L];if(e.setFromPoints(H,y.points),O.isSeparated(e)||(a.crossVectors(I,H),e.setFromPoints(a,y.points),t.setFromPoints(a,M.points),e.isSeparated(t)))return!1}return w&&(A||console.warn("ExtendedTriangle.intersectsTriangle: Triangles are coplanar which does not support an output edge. Setting edge to 0, 0, 0."),w.start.set(0,0,0),w.end.set(0,0,0)),!0}function p(y,M,w,A,I,D,T,S,P,L,O){let H=T/(T-S);L.x=A+(I-A)*H,O.start.subVectors(M,y).multiplyScalar(H).add(y),H=T/(T-P),L.y=A+(D-A)*H,O.end.subVectors(w,y).multiplyScalar(H).add(y)}function g(y,M,w,A,I,D,T,S,P,L,O){if(I>0)p(y.c,y.a,y.b,A,M,w,P,T,S,L,O);else if(D>0)p(y.b,y.a,y.c,w,M,A,S,T,P,L,O);else if(S*P>0||T!=0)p(y.a,y.b,y.c,M,w,A,T,S,P,L,O);else if(S!=0)p(y.b,y.a,y.c,w,M,A,S,T,P,L,O);else if(P!=0)p(y.c,y.a,y.b,A,M,w,P,T,S,L,O);else return!0;return!1}function b(y,M,w,A){let I=M.degenerateSegment,D=y.plane.distanceToPoint(I.start),T=y.plane.distanceToPoint(I.end);return Nn(D)?Nn(T)?l(y,M,w,A):(w&&(w.start.copy(I.start),w.end.copy(I.start)),y.containsPoint(I.start)):Nn(T)?(w&&(w.start.copy(I.end),w.end.copy(I.end)),y.containsPoint(I.end)):y.plane.intersectLine(I,n)!=null?(w&&(w.start.copy(n),w.end.copy(n)),y.containsPoint(n)):!1}function m(y,M,w){let A=M.a;return Nn(y.plane.distanceToPoint(A))&&y.containsPoint(A)?(w&&(w.start.copy(A),w.end.copy(A)),!0):!1}function d(y,M,w){let A=y.degenerateSegment,I=M.a;return A.closestPointToPoint(I,!0,n),I.distanceToSquared(n)<Ud?(w&&(w.start.copy(I),w.end.copy(I)),!0):!1}function _(y,M,w,A){if(y.isDegenerateIntoSegment)if(M.isDegenerateIntoSegment){let I=y.degenerateSegment,D=M.degenerateSegment,T=r,S=s;I.delta(T),D.delta(S);let P=n.subVectors(D.start,I.start),L=T.x*S.y-T.y*S.x;if(Nn(L))return!1;let O=(P.x*S.y-P.y*S.x)/L,H=-(T.x*P.y-T.y*P.x)/L;if(O<0||O>1||H<0||H>1)return!1;let q=I.start.z+T.z*O,Y=D.start.z+S.z*H;return Nn(q-Y)?(w&&(w.start.copy(I.start).addScaledVector(T,O),w.end.copy(I.start).addScaledVector(T,O)),!0):!1}else return M.isDegenerateIntoPoint?d(y,M,w):b(M,y,w,A);else{if(y.isDegenerateIntoPoint)return M.isDegenerateIntoPoint?M.a.distanceToSquared(y.a)<Ud?(w&&(w.start.copy(y.a),w.end.copy(y.a)),!0):!1:M.isDegenerateIntoSegment?d(M,y,w):m(M,y,w);if(M.isDegenerateIntoPoint)return m(y,M,w);if(M.isDegenerateIntoSegment)return b(y,M,w,A)}}return function(M,w=null,A=!1){this.needsUpdate&&this.update(),M.isExtendedTriangle?M.needsUpdate&&M.update():(i.copy(M),i.update(),M=i);let I=_(this,M,w,A);if(I!==void 0)return I;let D=this.plane,T=M.plane,S=T.distanceToPoint(this.a),P=T.distanceToPoint(this.b),L=T.distanceToPoint(this.c);Nn(S)&&(S=0),Nn(P)&&(P=0),Nn(L)&&(L=0);let O=S*P,H=S*L;if(O>0&&H>0)return!1;let q=D.distanceToPoint(M.a),Y=D.distanceToPoint(M.b),he=D.distanceToPoint(M.c);Nn(q)&&(q=0),Nn(Y)&&(Y=0),Nn(he)&&(he=0);let j=q*Y,le=q*he;if(j>0&&le>0)return!1;r.copy(D.normal),s.copy(T.normal);let ce=r.cross(s),we=0,Ce=Math.abs(ce.x),ke=Math.abs(ce.y);ke>Ce&&(Ce=ke,we=1),Math.abs(ce.z)>Ce&&(we=2);let nt=K_[we],K=this.a[nt],re=this.b[nt],be=this.c[nt],We=M.a[nt],Pe=M.b[nt],Qe=M.c[nt];if(g(this,K,re,be,O,H,S,P,L,f,o))return l(this,M,w,A);if(g(M,We,Pe,Qe,j,le,q,Y,he,h,c))return l(this,M,w,A);if(f.y<f.x){let Rt=f.y;f.y=f.x,f.x=Rt,u.copy(o.start),o.start.copy(o.end),o.end.copy(u)}if(h.y<h.x){let Rt=h.y;h.y=h.x,h.x=Rt,u.copy(c.start),c.start.copy(c.end),c.end.copy(u)}return f.y<h.x||h.y<f.x?!1:(w&&(h.x>f.x?w.start.copy(c.start):w.start.copy(o.start),h.y<f.y?w.end.copy(c.end):w.end.copy(o.end)),!0)}})();an.prototype.distanceToPoint=(function(){let i=new k;return function(t){return this.closestPointToPoint(t,i),t.distanceTo(i)}})();an.prototype.distanceToTriangle=(function(){let i=new k,e=new k,t=["a","b","c"],n=new gn,r=new gn;return function(a,o=null,c=null){let u=o||c?n:null;if(this.intersectsTriangle(a,u))return(o||c)&&(o&&u.getCenter(o),c&&u.getCenter(c)),0;let f=1/0;for(let h=0;h<3;h++){let l,p=t[h],g=a[p];this.closestPointToPoint(g,i),l=g.distanceToSquared(i),l<f&&(f=l,o&&o.copy(i),c&&c.copy(g));let b=this[p];a.closestPointToPoint(b,i),l=b.distanceToSquared(i),l<f&&(f=l,o&&o.copy(b),c&&c.copy(i))}for(let h=0;h<3;h++){let l=t[h],p=t[(h+1)%3];n.set(this[l],this[p]);for(let g=0;g<3;g++){let b=t[g],m=t[(g+1)%3];r.set(a[b],a[m]),ga(n,r,i,e);let d=i.distanceToSquared(e);d<f&&(f=d,o&&o.copy(i),c&&c.copy(e))}}return Math.sqrt(f)}})();var Ht=class{constructor(e,t,n){this.isOrientedBox=!0,this.min=new k,this.max=new k,this.matrix=new Xe,this.invMatrix=new Xe,this.points=new Array(8).fill().map(()=>new k),this.satAxes=new Array(3).fill().map(()=>new k),this.satBounds=new Array(3).fill().map(()=>new In),this.alignedSatBounds=new Array(3).fill().map(()=>new In),this.needsUpdate=!1,e&&this.min.copy(e),t&&this.max.copy(t),n&&this.matrix.copy(n)}set(e,t,n){this.min.copy(e),this.max.copy(t),this.matrix.copy(n),this.needsUpdate=!0}copy(e){this.min.copy(e.min),this.max.copy(e.max),this.matrix.copy(e.matrix),this.needsUpdate=!0}};Ht.prototype.update=(function(){return function(){let e=this.matrix,t=this.min,n=this.max,r=this.points;for(let u=0;u<=1;u++)for(let f=0;f<=1;f++)for(let h=0;h<=1;h++){let l=1*u|2*f|4*h,p=r[l];p.x=u?n.x:t.x,p.y=f?n.y:t.y,p.z=h?n.z:t.z,p.applyMatrix4(e)}let s=this.satBounds,a=this.satAxes,o=r[0];for(let u=0;u<3;u++){let f=a[u],h=s[u],l=1<<u,p=r[l];f.subVectors(o,p),h.setFromPoints(f,r)}let c=this.alignedSatBounds;c[0].setFromPointsField(r,"x"),c[1].setFromPointsField(r,"y"),c[2].setFromPointsField(r,"z"),this.invMatrix.copy(this.matrix).invert(),this.needsUpdate=!1}})();Ht.prototype.intersectsBox=(function(){let i=new In;return function(t){this.needsUpdate&&this.update();let n=t.min,r=t.max,s=this.satBounds,a=this.satAxes,o=this.alignedSatBounds;if(i.min=n.x,i.max=r.x,o[0].isSeparated(i)||(i.min=n.y,i.max=r.y,o[1].isSeparated(i))||(i.min=n.z,i.max=r.z,o[2].isSeparated(i)))return!1;for(let c=0;c<3;c++){let u=a[c],f=s[c];if(i.setFromBox(u,t),f.isSeparated(i))return!1}return!0}})();Ht.prototype.intersectsTriangle=(function(){let i=new an,e=new Array(3),t=new In,n=new In,r=new k;return function(a){this.needsUpdate&&this.update(),a.isExtendedTriangle?a.needsUpdate&&a.update():(i.copy(a),i.update(),a=i);let o=this.satBounds,c=this.satAxes;e[0]=a.a,e[1]=a.b,e[2]=a.c;for(let l=0;l<3;l++){let p=o[l],g=c[l];if(t.setFromPoints(g,e),p.isSeparated(t))return!1}let u=a.satBounds,f=a.satAxes,h=this.points;for(let l=0;l<3;l++){let p=u[l],g=f[l];if(t.setFromPoints(g,h),p.isSeparated(t))return!1}for(let l=0;l<3;l++){let p=c[l];for(let g=0;g<4;g++){let b=f[g];if(r.crossVectors(p,b),t.setFromPoints(r,e),n.setFromPoints(r,h),t.isSeparated(n))return!1}}return!0}})();Ht.prototype.closestPointToPoint=(function(){return function(e,t){return this.needsUpdate&&this.update(),t.copy(e).applyMatrix4(this.invMatrix).clamp(this.min,this.max).applyMatrix4(this.matrix),t}})();Ht.prototype.distanceToPoint=(function(){let i=new k;return function(t){return this.closestPointToPoint(t,i),t.distanceTo(i)}})();Ht.prototype.distanceToBox=(function(){let i=["x","y","z"],e=new Array(12).fill().map(()=>new gn),t=new Array(12).fill().map(()=>new gn),n=new k,r=new k;return function(a,o=0,c=null,u=null){if(this.needsUpdate&&this.update(),this.intersectsBox(a))return(c||u)&&(a.getCenter(r),this.closestPointToPoint(r,n),a.closestPointToPoint(n,r),c&&c.copy(n),u&&u.copy(r)),0;let f=o*o,h=a.min,l=a.max,p=this.points,g=1/0;for(let m=0;m<8;m++){let d=p[m];r.copy(d).clamp(h,l);let _=d.distanceToSquared(r);if(_<g&&(g=_,c&&c.copy(d),u&&u.copy(r),_<f))return Math.sqrt(_)}let b=0;for(let m=0;m<3;m++)for(let d=0;d<=1;d++)for(let _=0;_<=1;_++){let y=(m+1)%3,M=(m+2)%3,w=d<<y|_<<M,A=1<<m|d<<y|_<<M,I=p[w],D=p[A];e[b].set(I,D);let S=i[m],P=i[y],L=i[M],O=t[b],H=O.start,q=O.end;H[S]=h[S],H[P]=d?h[P]:l[P],H[L]=_?h[L]:l[P],q[S]=l[S],q[P]=d?h[P]:l[P],q[L]=_?h[L]:l[P],b++}for(let m=0;m<=1;m++)for(let d=0;d<=1;d++)for(let _=0;_<=1;_++){r.x=m?l.x:h.x,r.y=d?l.y:h.y,r.z=_?l.z:h.z,this.closestPointToPoint(r,n);let y=r.distanceToSquared(n);if(y<g&&(g=y,c&&c.copy(n),u&&u.copy(r),y<f))return Math.sqrt(y)}for(let m=0;m<12;m++){let d=e[m];for(let _=0;_<12;_++){let y=t[_];ga(d,y,n,r);let M=n.distanceToSquared(r);if(M<g&&(g=M,c&&c.copy(n),u&&u.copy(r),M<f))return Math.sqrt(M)}}return Math.sqrt(g)}})();var ih=class extends Vi{constructor(){super(()=>new an)}},_n=new ih;var xa=new k,rh=new k;function Bd(i,e,t={},n=0,r=1/0){let s=n*n,a=r*r,o=1/0,c=null;if(i.shapecast({boundsTraverseOrder:f=>(xa.copy(e).clamp(f.min,f.max),xa.distanceToSquared(e)),intersectsBounds:(f,h,l)=>l<o&&l<a,intersectsTriangle:(f,h)=>{f.closestPointToPoint(e,xa);let l=e.distanceToSquared(xa);return l<o&&(rh.copy(xa),o=l,c=h),l<s}}),o===1/0)return null;let u=Math.sqrt(o);return t.point?t.point.copy(rh):t.point=rh.clone(),t.distance=u,t.faceIndex=c,t}var Ec=parseInt("181")>=169,Q_=parseInt("181")<=161,fr=new k,dr=new k,pr=new k,Cc=new Le,Rc=new Le,Ic=new Le,Od=new k,zd=new k,kd=new k,va=new k;function j_(i,e,t,n,r,s,a,o){let c;if(s===Zt?c=i.intersectTriangle(n,t,e,!0,r):c=i.intersectTriangle(e,t,n,s!==fn,r),c===null)return null;let u=i.origin.distanceTo(r);return u<a||u>o?null:{distance:u,point:r.clone()}}function Vd(i,e,t,n,r,s,a,o,c,u,f){fr.fromBufferAttribute(e,s),dr.fromBufferAttribute(e,a),pr.fromBufferAttribute(e,o);let h=j_(i,fr,dr,pr,va,c,u,f);if(h){if(n){Cc.fromBufferAttribute(n,s),Rc.fromBufferAttribute(n,a),Ic.fromBufferAttribute(n,o),h.uv=new Le;let p=un.getInterpolation(va,fr,dr,pr,Cc,Rc,Ic,h.uv);Ec||(h.uv=p)}if(r){Cc.fromBufferAttribute(r,s),Rc.fromBufferAttribute(r,a),Ic.fromBufferAttribute(r,o),h.uv1=new Le;let p=un.getInterpolation(va,fr,dr,pr,Cc,Rc,Ic,h.uv1);Ec||(h.uv1=p),Q_&&(h.uv2=h.uv1)}if(t){Od.fromBufferAttribute(t,s),zd.fromBufferAttribute(t,a),kd.fromBufferAttribute(t,o),h.normal=new k;let p=un.getInterpolation(va,fr,dr,pr,Od,zd,kd,h.normal);h.normal.dot(i.direction)>0&&h.normal.multiplyScalar(-1),Ec||(h.normal=p)}let l={a:s,b:a,c:o,normal:new k,materialIndex:0};if(un.getNormal(fr,dr,pr,l.normal),h.face=l,h.faceIndex=s,Ec){let p=new k;un.getBarycoord(va,fr,dr,pr,p),h.barycoord=p}}return h}function Hd(i){return i&&i.isMaterial?i.side:i}function os(i,e,t,n,r,s,a){let o=n*3,c=o+0,u=o+1,f=o+2,{index:h,groups:l}=i;i.index&&(c=h.getX(c),u=h.getX(u),f=h.getX(f));let{position:p,normal:g,uv:b,uv1:m}=i.attributes;if(Array.isArray(e)){let d=n*3;for(let _=0,y=l.length;_<y;_++){let{start:M,count:w,materialIndex:A}=l[_];if(d>=M&&d<M+w){let I=Hd(e[A]),D=Vd(t,p,g,b,m,c,u,f,I,s,a);if(D)if(D.faceIndex=n,D.face.materialIndex=A,r)r.push(D);else return D}}}else{let d=Hd(e),_=Vd(t,p,g,b,m,c,u,f,d,s,a);if(_)if(_.faceIndex=n,_.face.materialIndex=0,r)r.push(_);else return _}return null}function Ct(i,e,t,n){let r=i.a,s=i.b,a=i.c,o=e,c=e+1,u=e+2;t&&(o=t.getX(o),c=t.getX(c),u=t.getX(u)),r.x=n.getX(o),r.y=n.getY(o),r.z=n.getZ(o),s.x=n.getX(c),s.y=n.getY(c),s.z=n.getZ(c),a.x=n.getX(u),a.y=n.getY(u),a.z=n.getZ(u)}function Gd(i,e,t,n,r,s,a,o){let{geometry:c,_indirectBuffer:u}=i;for(let f=n,h=n+r;f<h;f++)os(c,e,t,f,s,a,o)}function Wd(i,e,t,n,r,s,a){let{geometry:o,_indirectBuffer:c}=i,u=1/0,f=null;for(let h=n,l=n+r;h<l;h++){let p;p=os(o,e,t,h,null,s,a),p&&p.distance<u&&(f=p,u=p.distance)}return f}function Xd(i,e,t,n,r,s,a){let{geometry:o}=t,{index:c}=o,u=o.attributes.position;for(let f=i,h=e+i;f<h;f++){let l;if(l=f,Ct(a,l*3,c,u),a.needsUpdate=!0,n(a,l,r,s))return!0}return!1}function qd(i,e=null){e&&Array.isArray(e)&&(e=new Set(e));let t=i.geometry,n=t.index?t.index.array:null,r=t.attributes.position,s,a,o,c,u=0,f=i._roots;for(let l=0,p=f.length;l<p;l++)s=f[l],a=new Uint32Array(s),o=new Uint16Array(s),c=new Float32Array(s),h(0,u),u+=s.byteLength;function h(l,p,g=!1){let b=l*2;if(gt(b,o)){let m=a[l+6],d=o[b+14],_=1/0,y=1/0,M=1/0,w=-1/0,A=-1/0,I=-1/0;for(let D=3*m,T=3*(m+d);D<T;D++){let S=n[D],P=r.getX(S),L=r.getY(S),O=r.getZ(S);P<_&&(_=P),P>w&&(w=P),L<y&&(y=L),L>A&&(A=L),O<M&&(M=O),O>I&&(I=O)}return c[l+0]!==_||c[l+1]!==y||c[l+2]!==M||c[l+3]!==w||c[l+4]!==A||c[l+5]!==I?(c[l+0]=_,c[l+1]=y,c[l+2]=M,c[l+3]=w,c[l+4]=A,c[l+5]=I,!0):!1}else{let m=Mt(l),d=Tt(l,a),_=g,y=!1,M=!1;if(e){if(!_){let S=m/8+p/32,P=d/8+p/32;y=e.has(S),M=e.has(P),_=!y&&!M}}else y=!0,M=!0;let w=_||y,A=_||M,I=!1;w&&(I=h(m,p,_));let D=!1;A&&(D=h(d,p,_));let T=I||D;if(T)for(let S=0;S<3;S++){let P=m+S,L=d+S,O=c[P],H=c[P+3],q=c[L],Y=c[L+3];c[l+S]=O<q?O:q,c[l+S+3]=H>Y?H:Y}return T}}}function Un(i,e,t,n,r){let s,a,o,c,u,f,h=1/t.direction.x,l=1/t.direction.y,p=1/t.direction.z,g=t.origin.x,b=t.origin.y,m=t.origin.z,d=e[i],_=e[i+3],y=e[i+1],M=e[i+3+1],w=e[i+2],A=e[i+3+2];return h>=0?(s=(d-g)*h,a=(_-g)*h):(s=(_-g)*h,a=(d-g)*h),l>=0?(o=(y-b)*l,c=(M-b)*l):(o=(M-b)*l,c=(y-b)*l),s>c||o>a||((o>s||isNaN(s))&&(s=o),(c<a||isNaN(a))&&(a=c),p>=0?(u=(w-m)*p,f=(A-m)*p):(u=(A-m)*p,f=(w-m)*p),s>f||u>a)?!1:((u>s||s!==s)&&(s=u),(f<a||a!==a)&&(a=f),s<=r&&a>=n)}function Yd(i,e,t,n,r,s,a,o){let{geometry:c,_indirectBuffer:u}=i;for(let f=n,h=n+r;f<h;f++){let l=u?u[f]:f;os(c,e,t,l,s,a,o)}}function Zd(i,e,t,n,r,s,a){let{geometry:o,_indirectBuffer:c}=i,u=1/0,f=null;for(let h=n,l=n+r;h<l;h++){let p;p=os(o,e,t,c?c[h]:h,null,s,a),p&&p.distance<u&&(f=p,u=p.distance)}return f}function $d(i,e,t,n,r,s,a){let{geometry:o}=t,{index:c}=o,u=o.attributes.position;for(let f=i,h=e+i;f<h;f++){let l;if(l=t.resolveTriangleIndex(f),Ct(a,l*3,c,u),a.needsUpdate=!0,n(a,l,r,s))return!0}return!1}function Jd(i,e,t,n,r,s,a){pt.setBuffer(i._roots[e]),sh(0,i,t,n,r,s,a),pt.clearBuffer()}function sh(i,e,t,n,r,s,a){let{float32Array:o,uint16Array:c,uint32Array:u}=pt,f=i*2;if(gt(f,c)){let l=zt(i,u),p=Vt(f,c);Gd(e,t,n,l,p,r,s,a)}else{let l=Mt(i);Un(l,o,n,s,a)&&sh(l,e,t,n,r,s,a);let p=Tt(i,u);Un(p,o,n,s,a)&&sh(p,e,t,n,r,s,a)}}var ey=["x","y","z"];function Kd(i,e,t,n,r,s){pt.setBuffer(i._roots[e]);let a=ah(0,i,t,n,r,s);return pt.clearBuffer(),a}function ah(i,e,t,n,r,s){let{float32Array:a,uint16Array:o,uint32Array:c}=pt,u=i*2;if(gt(u,o)){let h=zt(i,c),l=Vt(u,o);return Wd(e,t,n,h,l,r,s)}else{let h=zi(i,c),l=ey[h],g=n.direction[l]>=0,b,m;g?(b=Mt(i),m=Tt(i,c)):(b=Tt(i,c),m=Mt(i));let _=Un(b,a,n,r,s)?ah(b,e,t,n,r,s):null;if(_){let w=_.point[l];if(g?w<=a[m+h]:w>=a[m+h+3])return _}let M=Un(m,a,n,r,s)?ah(m,e,t,n,r,s):null;return _&&M?_.distance<=M.distance?_:M:_||M||null}}var Pc=new Ut,cs=new an,ls=new an,_a=new Xe,Qd=new Ht,Dc=new Ht;function jd(i,e,t,n){pt.setBuffer(i._roots[e]);let r=oh(0,i,t,n);return pt.clearBuffer(),r}function oh(i,e,t,n,r=null){let{float32Array:s,uint16Array:a,uint32Array:o}=pt,c=i*2;if(r===null&&(t.boundingBox||t.computeBoundingBox(),Qd.set(t.boundingBox.min,t.boundingBox.max,n),r=Qd),gt(c,a)){let f=e.geometry,h=f.index,l=f.attributes.position,p=t.index,g=t.attributes.position,b=zt(i,o),m=Vt(c,a);if(_a.copy(n).invert(),t.boundsTree)return Et(i,s,Dc),Dc.matrix.copy(_a),Dc.needsUpdate=!0,t.boundsTree.shapecast({intersectsBounds:_=>Dc.intersectsBox(_),intersectsTriangle:_=>{_.a.applyMatrix4(n),_.b.applyMatrix4(n),_.c.applyMatrix4(n),_.needsUpdate=!0;for(let y=b*3,M=(m+b)*3;y<M;y+=3)if(Ct(ls,y,h,l),ls.needsUpdate=!0,_.intersectsTriangle(ls))return!0;return!1}});{let d=Gi(t);for(let _=b*3,y=(m+b)*3;_<y;_+=3){Ct(cs,_,h,l),cs.a.applyMatrix4(_a),cs.b.applyMatrix4(_a),cs.c.applyMatrix4(_a),cs.needsUpdate=!0;for(let M=0,w=d*3;M<w;M+=3)if(Ct(ls,M,p,g),ls.needsUpdate=!0,cs.intersectsTriangle(ls))return!0}}}else{let f=Mt(i),h=Tt(i,o);return Et(f,s,Pc),!!(r.intersectsBox(Pc)&&oh(f,e,t,n,r)||(Et(h,s,Pc),r.intersectsBox(Pc)&&oh(h,e,t,n,r)))}}var Fc=new Xe,ch=new Ht,ya=new Ht,ty=new k,ny=new k,iy=new k,ry=new k;function ep(i,e,t,n={},r={},s=0,a=1/0){e.boundingBox||e.computeBoundingBox(),ch.set(e.boundingBox.min,e.boundingBox.max,t),ch.needsUpdate=!0;let o=i.geometry,c=o.attributes.position,u=o.index,f=e.attributes.position,h=e.index,l=_n.getPrimitive(),p=_n.getPrimitive(),g=ty,b=ny,m=null,d=null;r&&(m=iy,d=ry);let _=1/0,y=null,M=null;return Fc.copy(t).invert(),ya.matrix.copy(Fc),i.shapecast({boundsTraverseOrder:w=>ch.distanceToBox(w),intersectsBounds:(w,A,I)=>I<_&&I<a?(A&&(ya.min.copy(w.min),ya.max.copy(w.max),ya.needsUpdate=!0),!0):!1,intersectsRange:(w,A)=>{if(e.boundsTree)return e.boundsTree.shapecast({boundsTraverseOrder:D=>ya.distanceToBox(D),intersectsBounds:(D,T,S)=>S<_&&S<a,intersectsRange:(D,T)=>{for(let S=D,P=D+T;S<P;S++){Ct(p,3*S,h,f),p.a.applyMatrix4(t),p.b.applyMatrix4(t),p.c.applyMatrix4(t),p.needsUpdate=!0;for(let L=w,O=w+A;L<O;L++){Ct(l,3*L,u,c),l.needsUpdate=!0;let H=l.distanceToTriangle(p,g,m);if(H<_&&(b.copy(g),d&&d.copy(m),_=H,y=L,M=S),H<s)return!0}}}});{let I=Gi(e);for(let D=0,T=I;D<T;D++){Ct(p,3*D,h,f),p.a.applyMatrix4(t),p.b.applyMatrix4(t),p.c.applyMatrix4(t),p.needsUpdate=!0;for(let S=w,P=w+A;S<P;S++){Ct(l,3*S,u,c),l.needsUpdate=!0;let L=l.distanceToTriangle(p,g,m);if(L<_&&(b.copy(g),d&&d.copy(m),_=L,y=S,M=D),L<s)return!0}}}}}),_n.releasePrimitive(l),_n.releasePrimitive(p),_===1/0?null:(n.point?n.point.copy(b):n.point=b.clone(),n.distance=_,n.faceIndex=y,r&&(r.point?r.point.copy(d):r.point=d.clone(),r.point.applyMatrix4(Fc),b.applyMatrix4(Fc),r.distance=b.sub(r.point).length(),r.faceIndex=M),n)}function tp(i,e=null){e&&Array.isArray(e)&&(e=new Set(e));let t=i.geometry,n=t.index?t.index.array:null,r=t.attributes.position,s,a,o,c,u=0,f=i._roots;for(let l=0,p=f.length;l<p;l++)s=f[l],a=new Uint32Array(s),o=new Uint16Array(s),c=new Float32Array(s),h(0,u),u+=s.byteLength;function h(l,p,g=!1){let b=l*2;if(gt(b,o)){let m=a[l+6],d=o[b+14],_=1/0,y=1/0,M=1/0,w=-1/0,A=-1/0,I=-1/0;for(let D=m,T=m+d;D<T;D++){let S=3*i.resolveTriangleIndex(D);for(let P=0;P<3;P++){let L=S+P;L=n?n[L]:L;let O=r.getX(L),H=r.getY(L),q=r.getZ(L);O<_&&(_=O),O>w&&(w=O),H<y&&(y=H),H>A&&(A=H),q<M&&(M=q),q>I&&(I=q)}}return c[l+0]!==_||c[l+1]!==y||c[l+2]!==M||c[l+3]!==w||c[l+4]!==A||c[l+5]!==I?(c[l+0]=_,c[l+1]=y,c[l+2]=M,c[l+3]=w,c[l+4]=A,c[l+5]=I,!0):!1}else{let m=Mt(l),d=Tt(l,a),_=g,y=!1,M=!1;if(e){if(!_){let S=m/8+p/32,P=d/8+p/32;y=e.has(S),M=e.has(P),_=!y&&!M}}else y=!0,M=!0;let w=_||y,A=_||M,I=!1;w&&(I=h(m,p,_));let D=!1;A&&(D=h(d,p,_));let T=I||D;if(T)for(let S=0;S<3;S++){let P=m+S,L=d+S,O=c[P],H=c[P+3],q=c[L],Y=c[L+3];c[l+S]=O<q?O:q,c[l+S+3]=H>Y?H:Y}return T}}}function np(i,e,t,n,r,s,a){pt.setBuffer(i._roots[e]),lh(0,i,t,n,r,s,a),pt.clearBuffer()}function lh(i,e,t,n,r,s,a){let{float32Array:o,uint16Array:c,uint32Array:u}=pt,f=i*2;if(gt(f,c)){let l=zt(i,u),p=Vt(f,c);Yd(e,t,n,l,p,r,s,a)}else{let l=Mt(i);Un(l,o,n,s,a)&&lh(l,e,t,n,r,s,a);let p=Tt(i,u);Un(p,o,n,s,a)&&lh(p,e,t,n,r,s,a)}}var sy=["x","y","z"];function ip(i,e,t,n,r,s){pt.setBuffer(i._roots[e]);let a=uh(0,i,t,n,r,s);return pt.clearBuffer(),a}function uh(i,e,t,n,r,s){let{float32Array:a,uint16Array:o,uint32Array:c}=pt,u=i*2;if(gt(u,o)){let h=zt(i,c),l=Vt(u,o);return Zd(e,t,n,h,l,r,s)}else{let h=zi(i,c),l=sy[h],g=n.direction[l]>=0,b,m;g?(b=Mt(i),m=Tt(i,c)):(b=Tt(i,c),m=Mt(i));let _=Un(b,a,n,r,s)?uh(b,e,t,n,r,s):null;if(_){let w=_.point[l];if(g?w<=a[m+h]:w>=a[m+h+3])return _}let M=Un(m,a,n,r,s)?uh(m,e,t,n,r,s):null;return _&&M?_.distance<=M.distance?_:M:_||M||null}}var Lc=new Ut,us=new an,hs=new an,ba=new Xe,rp=new Ht,Nc=new Ht;function sp(i,e,t,n){pt.setBuffer(i._roots[e]);let r=hh(0,i,t,n);return pt.clearBuffer(),r}function hh(i,e,t,n,r=null){let{float32Array:s,uint16Array:a,uint32Array:o}=pt,c=i*2;if(r===null&&(t.boundingBox||t.computeBoundingBox(),rp.set(t.boundingBox.min,t.boundingBox.max,n),r=rp),gt(c,a)){let f=e.geometry,h=f.index,l=f.attributes.position,p=t.index,g=t.attributes.position,b=zt(i,o),m=Vt(c,a);if(ba.copy(n).invert(),t.boundsTree)return Et(i,s,Nc),Nc.matrix.copy(ba),Nc.needsUpdate=!0,t.boundsTree.shapecast({intersectsBounds:_=>Nc.intersectsBox(_),intersectsTriangle:_=>{_.a.applyMatrix4(n),_.b.applyMatrix4(n),_.c.applyMatrix4(n),_.needsUpdate=!0;for(let y=b,M=m+b;y<M;y++)if(Ct(hs,3*e.resolveTriangleIndex(y),h,l),hs.needsUpdate=!0,_.intersectsTriangle(hs))return!0;return!1}});{let d=Gi(t);for(let _=b,y=m+b;_<y;_++){let M=e.resolveTriangleIndex(_);Ct(us,3*M,h,l),us.a.applyMatrix4(ba),us.b.applyMatrix4(ba),us.c.applyMatrix4(ba),us.needsUpdate=!0;for(let w=0,A=d*3;w<A;w+=3)if(Ct(hs,w,p,g),hs.needsUpdate=!0,us.intersectsTriangle(hs))return!0}}}else{let f=Mt(i),h=Tt(i,o);return Et(f,s,Lc),!!(r.intersectsBox(Lc)&&hh(f,e,t,n,r)||(Et(h,s,Lc),r.intersectsBox(Lc)&&hh(h,e,t,n,r)))}}var Uc=new Xe,fh=new Ht,Sa=new Ht,ay=new k,oy=new k,cy=new k,ly=new k;function ap(i,e,t,n={},r={},s=0,a=1/0){e.boundingBox||e.computeBoundingBox(),fh.set(e.boundingBox.min,e.boundingBox.max,t),fh.needsUpdate=!0;let o=i.geometry,c=o.attributes.position,u=o.index,f=e.attributes.position,h=e.index,l=_n.getPrimitive(),p=_n.getPrimitive(),g=ay,b=oy,m=null,d=null;r&&(m=cy,d=ly);let _=1/0,y=null,M=null;return Uc.copy(t).invert(),Sa.matrix.copy(Uc),i.shapecast({boundsTraverseOrder:w=>fh.distanceToBox(w),intersectsBounds:(w,A,I)=>I<_&&I<a?(A&&(Sa.min.copy(w.min),Sa.max.copy(w.max),Sa.needsUpdate=!0),!0):!1,intersectsRange:(w,A)=>{if(e.boundsTree){let I=e.boundsTree;return I.shapecast({boundsTraverseOrder:D=>Sa.distanceToBox(D),intersectsBounds:(D,T,S)=>S<_&&S<a,intersectsRange:(D,T)=>{for(let S=D,P=D+T;S<P;S++){let L=I.resolveTriangleIndex(S);Ct(p,3*L,h,f),p.a.applyMatrix4(t),p.b.applyMatrix4(t),p.c.applyMatrix4(t),p.needsUpdate=!0;for(let O=w,H=w+A;O<H;O++){let q=i.resolveTriangleIndex(O);Ct(l,3*q,u,c),l.needsUpdate=!0;let Y=l.distanceToTriangle(p,g,m);if(Y<_&&(b.copy(g),d&&d.copy(m),_=Y,y=O,M=S),Y<s)return!0}}}})}else{let I=Gi(e);for(let D=0,T=I;D<T;D++){Ct(p,3*D,h,f),p.a.applyMatrix4(t),p.b.applyMatrix4(t),p.c.applyMatrix4(t),p.needsUpdate=!0;for(let S=w,P=w+A;S<P;S++){let L=i.resolveTriangleIndex(S);Ct(l,3*L,u,c),l.needsUpdate=!0;let O=l.distanceToTriangle(p,g,m);if(O<_&&(b.copy(g),d&&d.copy(m),_=O,y=S,M=D),O<s)return!0}}}}}),_n.releasePrimitive(l),_n.releasePrimitive(p),_===1/0?null:(n.point?n.point.copy(b):n.point=b.clone(),n.distance=_,n.faceIndex=y,r&&(r.point?r.point.copy(d):r.point=d.clone(),r.point.applyMatrix4(Uc),b.applyMatrix4(Uc),r.distance=b.sub(r.point).length(),r.faceIndex=M),n)}var Ma=new pt.constructor,Bc=new pt.constructor,Wi=new Vi(()=>new Ut),fs=new Ut,ds=new Ut,dh=new Ut,ph=new Ut,mh=!1;function op(i,e,t,n){if(mh)throw new Error("MeshBVH: Recursive calls to bvhcast not supported.");mh=!0;let r=i._roots,s=e._roots,a,o=0,c=0,u=new Xe().copy(t).invert();for(let f=0,h=r.length;f<h;f++){Ma.setBuffer(r[f]),c=0;let l=Wi.getPrimitive();Et(0,Ma.float32Array,l),l.applyMatrix4(u);for(let p=0,g=s.length;p<g&&(Bc.setBuffer(s[p]),a=Yn(0,0,t,u,n,o,c,0,0,l),Bc.clearBuffer(),c+=s[p].byteLength/32,!a);p++);if(Wi.releasePrimitive(l),Ma.clearBuffer(),o+=r[f].byteLength/32,a)break}return mh=!1,a}function Yn(i,e,t,n,r,s=0,a=0,o=0,c=0,u=null,f=!1){let h,l;f?(h=Bc,l=Ma):(h=Ma,l=Bc);let p=h.float32Array,g=h.uint32Array,b=h.uint16Array,m=l.float32Array,d=l.uint32Array,_=l.uint16Array,y=i*2,M=e*2,w=gt(y,b),A=gt(M,_),I=!1;if(A&&w)f?I=r(zt(e,d),Vt(e*2,_),zt(i,g),Vt(i*2,b),c,a+e/8,o,s+i/8):I=r(zt(i,g),Vt(i*2,b),zt(e,d),Vt(e*2,_),o,s+i/8,c,a+e/8);else if(A){let D=Wi.getPrimitive();Et(e,m,D),D.applyMatrix4(t);let T=Mt(i),S=Tt(i,g);Et(T,p,fs),Et(S,p,ds);let P=D.intersectsBox(fs),L=D.intersectsBox(ds);I=P&&Yn(e,T,n,t,r,a,s,c,o+1,D,!f)||L&&Yn(e,S,n,t,r,a,s,c,o+1,D,!f),Wi.releasePrimitive(D)}else{let D=Mt(e),T=Tt(e,d);Et(D,m,dh),Et(T,m,ph);let S=u.intersectsBox(dh),P=u.intersectsBox(ph);if(S&&P)I=Yn(i,D,t,n,r,s,a,o,c+1,u,f)||Yn(i,T,t,n,r,s,a,o,c+1,u,f);else if(S)if(w)I=Yn(i,D,t,n,r,s,a,o,c+1,u,f);else{let L=Wi.getPrimitive();L.copy(dh).applyMatrix4(t);let O=Mt(i),H=Tt(i,g);Et(O,p,fs),Et(H,p,ds);let q=L.intersectsBox(fs),Y=L.intersectsBox(ds);I=q&&Yn(D,O,n,t,r,a,s,c,o+1,L,!f)||Y&&Yn(D,H,n,t,r,a,s,c,o+1,L,!f),Wi.releasePrimitive(L)}else if(P)if(w)I=Yn(i,T,t,n,r,s,a,o,c+1,u,f);else{let L=Wi.getPrimitive();L.copy(ph).applyMatrix4(t);let O=Mt(i),H=Tt(i,g);Et(O,p,fs),Et(H,p,ds);let q=L.intersectsBox(fs),Y=L.intersectsBox(ds);I=q&&Yn(T,O,n,t,r,a,s,c,o+1,L,!f)||Y&&Yn(T,H,n,t,r,a,s,c,o+1,L,!f),Wi.releasePrimitive(L)}}return I}function gh(i,e,t){return i===null?null:(i.point.applyMatrix4(e.matrixWorld),i.distance=i.point.distanceTo(t.ray.origin),i.object=e,i)}function cp(){return typeof SharedArrayBuffer<"u"}function uy(i,e){let t=i[i.length-1],n=t.offset+t.count>2**16,r=i.reduce((u,f)=>u+f.count,0),s=n?4:2,a=e?new SharedArrayBuffer(r*s):new ArrayBuffer(r*s),o=n?new Uint32Array(a):new Uint16Array(a),c=0;for(let u=0;u<i.length;u++){let{offset:f,count:h}=i[u];for(let l=0;l<h;l++)o[c+l]=f+l;c+=h}return o}var Oc=class extends Ac{get indirect(){return!!this._indirectBuffer}get primitiveStride(){return null}get primitiveBufferStride(){return this.indirect?1:this.primitiveStride}set primitiveBufferStride(e){}get primitiveBuffer(){return this.indirect?this._indirectBuffer:this.geometry.index.array}set primitiveBuffer(e){}constructor(e,t={}){if(e.isBufferGeometry){if(e.index&&e.index.isInterleavedBufferAttribute)throw new Error("BVH: InterleavedBufferAttribute is not supported for the index attribute.")}else throw new Error("BVH: Only BufferGeometries are supported.");if(t.useSharedArrayBuffer&&!cp())throw new Error("BVH: SharedArrayBuffer is not available.");super(),this.geometry=e,this.resolvePrimitiveIndex=t.indirect?n=>this._indirectBuffer[n]:n=>n,this.primitiveBuffer=null,this.primitiveBufferStride=null,this._indirectBuffer=null,t={..._c,...t},t[fa]||this.init(t)}init(e){let{geometry:t,primitiveStride:n}=this;if(e.indirect){let r=ma(t,e.range,n),s=uy(r,e.useSharedArrayBuffer);this._indirectBuffer=s}else Fd(t,e);super.init(e),!t.boundingBox&&e.setBoundingBox&&(t.boundingBox=this.getBoundingBox(new Ut))}computePrimitiveBounds(){throw new Error("BVH: computePrimitiveBounds() not implemented")}getRootRanges(e){return this.indirect?[{offset:0,count:this._indirectBuffer.length}]:ma(this.geometry,e,this.primitiveStride)}raycastObject3D(){throw new Error("BVH: raycastObject3D() not implemented")}shapecast(e){let{iterateDirect:t,iterateIndirect:n,...r}=e,s=this.indirect?n:t;return super.shapecast({...r,iterate:s})}};var zc=new Ht,kc=new Xr,lp=new k,up=new Xe,hp=new k,Vc=class i extends Oc{static serialize(e,t={}){t={cloneBuffers:!0,...t};let n=e.geometry,r=e._roots,s=e._indirectBuffer,a=n.getIndex(),o={version:1,roots:null,index:null,indirectBuffer:null};return t.cloneBuffers?(o.roots=r.map(c=>c.slice()),o.index=a?a.array.slice():null,o.indirectBuffer=s?s.slice():null):(o.roots=r,o.index=a?a.array:null,o.indirectBuffer=s),o}static deserialize(e,t,n={}){n={setIndex:!0,indirect:!!e.indirectBuffer,...n};let{index:r,roots:s,indirectBuffer:a}=e;e.version||(console.warn("MeshBVH.deserialize: Serialization format has been changed and will be fixed up. It is recommended to regenerate any stored serialized data."),c(s));let o=new i(t,{...n,[fa]:!0});if(o._roots=s,o._indirectBuffer=a||null,n.setIndex){let u=t.getIndex();if(u===null){let f=new mt(e.index,1,!1);t.setIndex(f)}else u.array!==r&&(u.array.set(r),u.needsUpdate=!0)}return o;function c(u){for(let f=0;f<u.length;f++){let h=u[f],l=new Uint32Array(h),p=new Uint16Array(h);for(let g=0,b=h.byteLength/32;g<b;g++){let m=8*g,d=2*m;gt(d,p)||(l[m+6]=l[m+6]/8-g)}}}}get primitiveStride(){return 3}get resolveTriangleIndex(){return this.resolvePrimitiveIndex}constructor(e,t={}){t.maxLeafTris&&(t={...t,maxLeafSize:t.maxLeafTris}),super(e,t)}shiftTriangleOffsets(e){return super.shiftPrimitiveOffsets(e)}computePrimitiveBounds(e,t,n){let r=this.geometry,s=this._indirectBuffer,a=r.attributes.position,o=r.index?r.index.array:null,c=a.normalized;if(e<0||t+e-n.offset>n.length/6)throw new Error("MeshBVH: compute triangle bounds range is invalid.");let u=a.array,f=a.offset||0,h=3;a.isInterleavedBufferAttribute&&(h=a.data.stride);let l=["getX","getY","getZ"],p=n.offset;for(let g=e,b=e+t;g<b;g++){let d=(s?s[g]:g)*3,_=(g-p)*6,y=d+0,M=d+1,w=d+2;o&&(y=o[y],M=o[M],w=o[w]),c||(y=y*h+f,M=M*h+f,w=w*h+f);for(let A=0;A<3;A++){let I,D,T;c?(I=a[l[A]](y),D=a[l[A]](M),T=a[l[A]](w)):(I=u[y+A],D=u[M+A],T=u[w+A]);let S=I;D<S&&(S=D),T<S&&(S=T);let P=I;D>P&&(P=D),T>P&&(P=T);let L=(P-S)/2,O=A*2;n[_+O+0]=S+L,n[_+O+1]=L+(Math.abs(S)+L)*Md}}return n}raycastObject3D(e,t,n=[]){let{material:r}=e;if(r===void 0)return;up.copy(e.matrixWorld).invert(),kc.copy(t.ray).applyMatrix4(up),hp.setFromMatrixScale(e.matrixWorld),lp.copy(kc.direction).multiply(hp);let s=lp.length(),a=t.near/s,o=t.far/s;if(t.firstHitOnly===!0){let c=this.raycastFirst(kc,r,a,o);c=gh(c,e,t),c&&n.push(c)}else{let c=this.raycast(kc,r,a,o);for(let u=0,f=c.length;u<f;u++){let h=gh(c[u],e,t);h&&n.push(h)}}return n}refit(e=null){return(this.indirect?tp:qd)(this,e)}raycast(e,t=Mn,n=0,r=1/0){let s=this._roots,a=[],o=this.indirect?np:Jd;for(let c=0,u=s.length;c<u;c++)o(this,c,t,e,a,n,r);return a}raycastFirst(e,t=Mn,n=0,r=1/0){let s=this._roots,a=null,o=this.indirect?ip:Kd;for(let c=0,u=s.length;c<u;c++){let f=o(this,c,t,e,n,r);f!=null&&(a==null||f.distance<a.distance)&&(a=f)}return a}intersectsGeometry(e,t){let n=!1,r=this._roots,s=this.indirect?sp:jd;for(let a=0,o=r.length;a<o&&(n=s(this,a,e,t),!n);a++);return n}shapecast(e){let t=_n.getPrimitive(),n=super.shapecast({...e,intersectsPrimitive:e.intersectsTriangle,scratchPrimitive:t,iterateDirect:Xd,iterateIndirect:$d});return _n.releasePrimitive(t),n}bvhcast(e,t,n){let{intersectsRanges:r,intersectsTriangles:s}=n,a=_n.getPrimitive(),o=this.geometry.index,c=this.geometry.attributes.position,u=this.indirect?g=>{let b=this.resolveTriangleIndex(g);Ct(a,b*3,o,c)}:g=>{Ct(a,g*3,o,c)},f=_n.getPrimitive(),h=e.geometry.index,l=e.geometry.attributes.position,p=e.indirect?g=>{let b=e.resolveTriangleIndex(g);Ct(f,b*3,h,l)}:g=>{Ct(f,g*3,h,l)};if(s){let g=(b,m,d,_,y,M,w,A)=>{for(let I=d,D=d+_;I<D;I++){p(I),f.a.applyMatrix4(t),f.b.applyMatrix4(t),f.c.applyMatrix4(t),f.needsUpdate=!0;for(let T=b,S=b+m;T<S;T++)if(u(T),a.needsUpdate=!0,s(a,f,T,I,y,M,w,A))return!0}return!1};if(r){let b=r;r=function(m,d,_,y,M,w,A,I){return b(m,d,_,y,M,w,A,I)?!0:g(m,d,_,y,M,w,A,I)}}else r=g}return op(this,e,t,r)}intersectsBox(e,t){return zc.set(e.min,e.max,t),zc.needsUpdate=!0,this.shapecast({intersectsBounds:n=>zc.intersectsBox(n),intersectsTriangle:n=>zc.intersectsTriangle(n)})}intersectsSphere(e){return this.shapecast({intersectsBounds:t=>e.intersectsBox(t),intersectsTriangle:t=>t.intersectsSphere(e)})}closestPointToGeometry(e,t,n={},r={},s=0,a=1/0){return(this.indirect?ap:ep)(this,e,t,n,r,s,a)}closestPointToPoint(e,t={},n=0,r=1/0){return Bd(this,e,t,n,r)}};function hy(i){switch(i){case 1:return"R";case 2:return"RG";case 3:return"RGBA";case 4:return"RGBA"}throw new Error}function fy(i){switch(i){case 1:return vn;case 2:return Tn;case 3:return He;case 4:return He}}function fp(i){switch(i){case 1:return jr;case 2:return Ui;case 3:return Bi;case 4:return Bi}}var Hc=class extends St{constructor(){super(),this.minFilter=je,this.magFilter=je,this.generateMipmaps=!1,this.overrideItemSize=null,this._forcedType=null}updateFrom(e){let t=this.overrideItemSize,n=e.itemSize,r=e.count;if(t!==null){if(n*r%t!==0)throw new Error("VertexAttributeTexture: overrideItemSize must divide evenly into buffer length.");e.itemSize=t,e.count=r*n/t}let s=e.itemSize,a=e.count,o=e.normalized,c=e.array.constructor,u=c.BYTES_PER_ELEMENT,f=this._forcedType,h=s;if(f===null)switch(c){case Float32Array:f=qe;break;case Uint8Array:case Uint16Array:case Uint32Array:f=xn;break;case Int8Array:case Int16Array:case Int32Array:f=Ni;break}let l,p,g,b,m=hy(s);switch(f){case qe:g=1,p=fy(s),o&&u===1?(b=c,m+="8",c===Uint8Array?l=dn:(l=Jr,m+="_SNORM")):(b=Float32Array,m+="32F",l=qe);break;case Ni:m+=u*8+"I",g=o?Math.pow(2,c.BYTES_PER_ELEMENT*8-1):1,p=fp(s),u===1?(b=Int8Array,l=Jr):u===2?(b=Int16Array,l=ra):(b=Int32Array,l=Ni);break;case xn:m+=u*8+"UI",g=o?Math.pow(2,c.BYTES_PER_ELEMENT*8-1):1,p=fp(s),u===1?(b=Uint8Array,l=dn):u===2?(b=Uint16Array,l=Li):(b=Uint32Array,l=xn);break}h===3&&(p===He||p===Bi)&&(h=4);let d=Math.ceil(Math.sqrt(a))||1,_=h*d*d,y=new b(_),M=e.normalized;e.normalized=!1;for(let w=0;w<a;w++){let A=h*w;y[A]=e.getX(w)/g,s>=2&&(y[A+1]=e.getY(w)/g),s>=3&&(y[A+2]=e.getZ(w)/g,h===4&&(y[A+3]=1)),s>=4&&(y[A+3]=e.getW(w)/g)}e.normalized=M,this.internalFormat=m,this.format=p,this.type=l,this.image.width=d,this.image.height=d,this.image.data=y,this.needsUpdate=!0,this.dispose(),e.itemSize=n,e.count=r}},ps=class extends Hc{constructor(){super(),this._forcedType=xn}};var ms=class extends Hc{constructor(){super(),this._forcedType=qe}};var Gc=class{constructor(){this.index=new ps,this.position=new ms,this.bvhBounds=new St,this.bvhContents=new St,this._cachedIndexAttr=null,this.index.overrideItemSize=3}updateFrom(e){let{geometry:t}=e;if(py(e,this.bvhBounds,this.bvhContents),this.position.updateFrom(t.attributes.position),e.indirect){let n=e._indirectBuffer;if(this._cachedIndexAttr===null||this._cachedIndexAttr.count!==n.length)if(t.index)this._cachedIndexAttr=t.index.clone();else{let r=nh(pa(t));this._cachedIndexAttr=new mt(r,1,!1)}dy(t,n,this._cachedIndexAttr),this.index.updateFrom(this._cachedIndexAttr)}else this.index.updateFrom(t.index)}dispose(){let{index:e,position:t,bvhBounds:n,bvhContents:r}=this;e&&e.dispose(),t&&t.dispose(),n&&n.dispose(),r&&r.dispose()}};function dy(i,e,t){let n=t.array,r=i.index?i.index.array:null;for(let s=0,a=e.length;s<a;s++){let o=3*s,c=3*e[s];for(let u=0;u<3;u++)n[o+u]=r?r[c+u]:c+u}}function py(i,e,t){let n=i._roots;if(n.length!==1)throw new Error("MeshBVHUniformStruct: Multi-root BVHs not supported.");let r=n[0],s=new Uint16Array(r),a=new Uint32Array(r),o=new Float32Array(r),c=r.byteLength/32,u=2*Math.ceil(Math.sqrt(c/2)),f=new Float32Array(4*u*u),h=Math.ceil(Math.sqrt(c)),l=new Uint32Array(2*h*h);for(let p=0;p<c;p++){let g=p*32/4,b=g*2,m=g;for(let d=0;d<3;d++)f[8*p+0+d]=o[m+0+d],f[8*p+4+d]=o[m+3+d];if(gt(b,s)){let d=Vt(b,s),_=zt(g,a),y=-65536|d;l[p*2+0]=y,l[p*2+1]=_}else{let d=a[g+6],_=zi(g,a);l[p*2+0]=_,l[p*2+1]=d}}e.image.data=f,e.image.width=u,e.image.height=u,e.format=He,e.type=qe,e.internalFormat="RGBA32F",e.minFilter=je,e.magFilter=je,e.generateMipmaps=!1,e.needsUpdate=!0,e.dispose(),t.image.data=l,t.image.width=h,t.image.height=h,t.format=Ui,t.type=xn,t.internalFormat="RG32UI",t.minFilter=je,t.magFilter=je,t.generateMipmaps=!1,t.needsUpdate=!0,t.dispose()}var mr={};Tm(mr,{bvh_distance_functions:()=>dp,bvh_ray_functions:()=>vh,bvh_struct_definitions:()=>pp,common_functions:()=>xh});var xh=`

// A stack of uint32 indices can can store the indices for
// a perfectly balanced tree with a depth up to 31. Lower stack
// depth gets higher performance.
//
// However not all trees are balanced. Best value to set this to
// is the trees max depth.
#ifndef BVH_STACK_DEPTH
#define BVH_STACK_DEPTH 60
#endif

#ifndef INFINITY
#define INFINITY 1e20
#endif

// Utilities
uvec4 uTexelFetch1D( usampler2D tex, uint index ) {

	uint width = uint( textureSize( tex, 0 ).x );
	uvec2 uv;
	uv.x = index % width;
	uv.y = index / width;

	return texelFetch( tex, ivec2( uv ), 0 );

}

ivec4 iTexelFetch1D( isampler2D tex, uint index ) {

	uint width = uint( textureSize( tex, 0 ).x );
	uvec2 uv;
	uv.x = index % width;
	uv.y = index / width;

	return texelFetch( tex, ivec2( uv ), 0 );

}

vec4 texelFetch1D( sampler2D tex, uint index ) {

	uint width = uint( textureSize( tex, 0 ).x );
	uvec2 uv;
	uv.x = index % width;
	uv.y = index / width;

	return texelFetch( tex, ivec2( uv ), 0 );

}

vec4 textureSampleBarycoord( sampler2D tex, vec3 barycoord, uvec3 faceIndices ) {

	return
		barycoord.x * texelFetch1D( tex, faceIndices.x ) +
		barycoord.y * texelFetch1D( tex, faceIndices.y ) +
		barycoord.z * texelFetch1D( tex, faceIndices.z );

}

void ndcToCameraRay(
	vec2 coord, mat4 cameraWorld, mat4 invProjectionMatrix,
	out vec3 rayOrigin, out vec3 rayDirection
) {

	// get camera look direction and near plane for camera clipping
	vec4 lookDirection = cameraWorld * vec4( 0.0, 0.0, - 1.0, 0.0 );
	vec4 nearVector = invProjectionMatrix * vec4( 0.0, 0.0, - 1.0, 1.0 );
	float near = abs( nearVector.z / nearVector.w );

	// get the camera direction and position from camera matrices
	vec4 origin = cameraWorld * vec4( 0.0, 0.0, 0.0, 1.0 );
	vec4 direction = invProjectionMatrix * vec4( coord, 0.5, 1.0 );
	direction /= direction.w;
	direction = cameraWorld * direction - origin;

	// slide the origin along the ray until it sits at the near clip plane position
	origin.xyz += direction.xyz * near / dot( direction, lookDirection );

	rayOrigin = origin.xyz;
	rayDirection = direction.xyz;

}
`;var dp=`

float dot2( vec3 v ) {

	return dot( v, v );

}

// https://www.shadertoy.com/view/ttfGWl
vec3 closestPointToTriangle( vec3 p, vec3 v0, vec3 v1, vec3 v2, out vec3 barycoord ) {

    vec3 v10 = v1 - v0;
    vec3 v21 = v2 - v1;
    vec3 v02 = v0 - v2;

	vec3 p0 = p - v0;
	vec3 p1 = p - v1;
	vec3 p2 = p - v2;

    vec3 nor = cross( v10, v02 );

    // method 2, in barycentric space
    vec3  q = cross( nor, p0 );
    float d = 1.0 / dot2( nor );
    float u = d * dot( q, v02 );
    float v = d * dot( q, v10 );
    float w = 1.0 - u - v;

	if( u < 0.0 ) {

		w = clamp( dot( p2, v02 ) / dot2( v02 ), 0.0, 1.0 );
		u = 0.0;
		v = 1.0 - w;

	} else if( v < 0.0 ) {

		u = clamp( dot( p0, v10 ) / dot2( v10 ), 0.0, 1.0 );
		v = 0.0;
		w = 1.0 - u;

	} else if( w < 0.0 ) {

		v = clamp( dot( p1, v21 ) / dot2( v21 ), 0.0, 1.0 );
		w = 0.0;
		u = 1.0 - v;

	}

	barycoord = vec3( u, v, w );
    return u * v1 + v * v2 + w * v0;

}

float distanceToTriangles(
	// geometry info and triangle range
	sampler2D positionAttr, usampler2D indexAttr, uint offset, uint count,

	// point and cut off range
	vec3 point, float closestDistanceSquared,

	// outputs
	inout uvec4 faceIndices, inout vec3 faceNormal, inout vec3 barycoord, inout float side, inout vec3 outPoint
) {

	bool found = false;
	vec3 localBarycoord;
	for ( uint i = offset, l = offset + count; i < l; i ++ ) {

		uvec3 indices = uTexelFetch1D( indexAttr, i ).xyz;
		vec3 a = texelFetch1D( positionAttr, indices.x ).rgb;
		vec3 b = texelFetch1D( positionAttr, indices.y ).rgb;
		vec3 c = texelFetch1D( positionAttr, indices.z ).rgb;

		// get the closest point and barycoord
		vec3 closestPoint = closestPointToTriangle( point, a, b, c, localBarycoord );
		vec3 delta = point - closestPoint;
		float sqDist = dot2( delta );
		if ( sqDist < closestDistanceSquared ) {

			// set the output results
			closestDistanceSquared = sqDist;
			faceIndices = uvec4( indices.xyz, i );
			faceNormal = normalize( cross( a - b, b - c ) );
			barycoord = localBarycoord;
			outPoint = closestPoint;
			side = sign( dot( faceNormal, delta ) );

		}

	}

	return closestDistanceSquared;

}

float distanceSqToBounds( vec3 point, vec3 boundsMin, vec3 boundsMax ) {

	vec3 clampedPoint = clamp( point, boundsMin, boundsMax );
	vec3 delta = point - clampedPoint;
	return dot( delta, delta );

}

float distanceSqToBVHNodeBoundsPoint( vec3 point, sampler2D bvhBounds, uint currNodeIndex ) {

	uint cni2 = currNodeIndex * 2u;
	vec3 boundsMin = texelFetch1D( bvhBounds, cni2 ).xyz;
	vec3 boundsMax = texelFetch1D( bvhBounds, cni2 + 1u ).xyz;
	return distanceSqToBounds( point, boundsMin, boundsMax );

}

// use a macro to hide the fact that we need to expand the struct into separate fields
#define	bvhClosestPointToPoint(		bvh,		point, maxDistance, faceIndices, faceNormal, barycoord, side, outPoint	)	_bvhClosestPointToPoint(		bvh.position, bvh.index, bvh.bvhBounds, bvh.bvhContents,		point, maxDistance, faceIndices, faceNormal, barycoord, side, outPoint	)

float _bvhClosestPointToPoint(
	// bvh info
	sampler2D bvh_position, usampler2D bvh_index, sampler2D bvh_bvhBounds, usampler2D bvh_bvhContents,

	// point to check
	vec3 point, float maxDistance,

	// output variables
	inout uvec4 faceIndices, inout vec3 faceNormal, inout vec3 barycoord,
	inout float side, inout vec3 outPoint
 ) {

	// stack needs to be twice as long as the deepest tree we expect because
	// we push both the left and right child onto the stack every traversal
	int ptr = 0;
	uint stack[ BVH_STACK_DEPTH ];
	stack[ 0 ] = 0u;

	float closestDistanceSquared = maxDistance * maxDistance;
	bool found = false;
	while ( ptr > - 1 && ptr < BVH_STACK_DEPTH ) {

		uint currNodeIndex = stack[ ptr ];
		ptr --;

		// check if we intersect the current bounds
		float boundsHitDistance = distanceSqToBVHNodeBoundsPoint( point, bvh_bvhBounds, currNodeIndex );
		if ( boundsHitDistance > closestDistanceSquared ) {

			continue;

		}

		uvec2 boundsInfo = uTexelFetch1D( bvh_bvhContents, currNodeIndex ).xy;
		bool isLeaf = bool( boundsInfo.x & 0xffff0000u );
		if ( isLeaf ) {

			uint count = boundsInfo.x & 0x0000ffffu;
			uint offset = boundsInfo.y;
			closestDistanceSquared = distanceToTriangles(
				bvh_position, bvh_index, offset, count, point, closestDistanceSquared,

				// outputs
				faceIndices, faceNormal, barycoord, side, outPoint
			);

		} else {

			uint leftIndex = currNodeIndex + 1u;
			uint splitAxis = boundsInfo.x & 0x0000ffffu;
			uint rightIndex = currNodeIndex + boundsInfo.y;
			bool leftToRight = distanceSqToBVHNodeBoundsPoint( point, bvh_bvhBounds, leftIndex ) < distanceSqToBVHNodeBoundsPoint( point, bvh_bvhBounds, rightIndex );//rayDirection[ splitAxis ] >= 0.0;
			uint c1 = leftToRight ? leftIndex : rightIndex;
			uint c2 = leftToRight ? rightIndex : leftIndex;

			// set c2 in the stack so we traverse it later. We need to keep track of a pointer in
			// the stack while we traverse. The second pointer added is the one that will be
			// traversed first
			ptr ++;
			stack[ ptr ] = c2;
			ptr ++;
			stack[ ptr ] = c1;

		}

	}

	return sqrt( closestDistanceSquared );

}
`;var vh=`

#ifndef TRI_INTERSECT_EPSILON
#define TRI_INTERSECT_EPSILON 1e-5
#endif

// Raycasting
bool intersectsBounds( vec3 rayOrigin, vec3 rayDirection, vec3 boundsMin, vec3 boundsMax, out float dist ) {

	// https://www.reddit.com/r/opengl/comments/8ntzz5/fast_glsl_ray_box_intersection/
	// https://tavianator.com/2011/ray_box.html
	vec3 invDir = 1.0 / rayDirection;

	// find intersection distances for each plane
	vec3 tMinPlane = invDir * ( boundsMin - rayOrigin );
	vec3 tMaxPlane = invDir * ( boundsMax - rayOrigin );

	// get the min and max distances from each intersection
	vec3 tMinHit = min( tMaxPlane, tMinPlane );
	vec3 tMaxHit = max( tMaxPlane, tMinPlane );

	// get the furthest hit distance
	vec2 t = max( tMinHit.xx, tMinHit.yz );
	float t0 = max( t.x, t.y );

	// get the minimum hit distance
	t = min( tMaxHit.xx, tMaxHit.yz );
	float t1 = min( t.x, t.y );

	// set distance to 0.0 if the ray starts inside the box
	dist = max( t0, 0.0 );

	return t1 >= dist;

}

bool intersectsTriangle(
	vec3 rayOrigin, vec3 rayDirection, vec3 a, vec3 b, vec3 c,
	out vec3 barycoord, out vec3 norm, out float dist, out float side
) {

	// https://stackoverflow.com/questions/42740765/intersection-between-line-and-triangle-in-3d
	vec3 edge1 = b - a;
	vec3 edge2 = c - a;
	norm = cross( edge1, edge2 );

	float det = - dot( rayDirection, norm );
	float invdet = 1.0 / det;

	vec3 AO = rayOrigin - a;
	vec3 DAO = cross( AO, rayDirection );

	vec4 uvt;
	uvt.x = dot( edge2, DAO ) * invdet;
	uvt.y = - dot( edge1, DAO ) * invdet;
	uvt.z = dot( AO, norm ) * invdet;
	uvt.w = 1.0 - uvt.x - uvt.y;

	// set the hit information
	barycoord = uvt.wxy; // arranged in A, B, C order
	dist = uvt.z;
	side = sign( det );
	norm = side * normalize( norm );

	// add an epsilon to avoid misses between triangles
	uvt += vec4( TRI_INTERSECT_EPSILON );

	return all( greaterThanEqual( uvt, vec4( 0.0 ) ) );

}

bool intersectTriangles(
	// geometry info and triangle range
	sampler2D positionAttr, usampler2D indexAttr, uint offset, uint count,

	// ray
	vec3 rayOrigin, vec3 rayDirection,

	// outputs
	inout float minDistance, inout uvec4 faceIndices, inout vec3 faceNormal, inout vec3 barycoord,
	inout float side, inout float dist
) {

	bool found = false;
	vec3 localBarycoord, localNormal;
	float localDist, localSide;
	for ( uint i = offset, l = offset + count; i < l; i ++ ) {

		uvec3 indices = uTexelFetch1D( indexAttr, i ).xyz;
		vec3 a = texelFetch1D( positionAttr, indices.x ).rgb;
		vec3 b = texelFetch1D( positionAttr, indices.y ).rgb;
		vec3 c = texelFetch1D( positionAttr, indices.z ).rgb;

		if (
			intersectsTriangle( rayOrigin, rayDirection, a, b, c, localBarycoord, localNormal, localDist, localSide )
			&& localDist < minDistance
		) {

			found = true;
			minDistance = localDist;

			faceIndices = uvec4( indices.xyz, i );
			faceNormal = localNormal;

			side = localSide;
			barycoord = localBarycoord;
			dist = localDist;

		}

	}

	return found;

}

bool intersectsBVHNodeBounds( vec3 rayOrigin, vec3 rayDirection, sampler2D bvhBounds, uint currNodeIndex, out float dist ) {

	uint cni2 = currNodeIndex * 2u;
	vec3 boundsMin = texelFetch1D( bvhBounds, cni2 ).xyz;
	vec3 boundsMax = texelFetch1D( bvhBounds, cni2 + 1u ).xyz;
	return intersectsBounds( rayOrigin, rayDirection, boundsMin, boundsMax, dist );

}

// use a macro to hide the fact that we need to expand the struct into separate fields
#define	bvhIntersectFirstHit(		bvh,		rayOrigin, rayDirection, faceIndices, faceNormal, barycoord, side, dist	)	_bvhIntersectFirstHit(		bvh.position, bvh.index, bvh.bvhBounds, bvh.bvhContents,		rayOrigin, rayDirection, faceIndices, faceNormal, barycoord, side, dist	)

bool _bvhIntersectFirstHit(
	// bvh info
	sampler2D bvh_position, usampler2D bvh_index, sampler2D bvh_bvhBounds, usampler2D bvh_bvhContents,

	// ray
	vec3 rayOrigin, vec3 rayDirection,

	// output variables split into separate variables due to output precision
	inout uvec4 faceIndices, inout vec3 faceNormal, inout vec3 barycoord,
	inout float side, inout float dist
) {

	// stack needs to be twice as long as the deepest tree we expect because
	// we push both the left and right child onto the stack every traversal
	int ptr = 0;
	uint stack[ BVH_STACK_DEPTH ];
	stack[ 0 ] = 0u;

	float triangleDistance = INFINITY;
	bool found = false;
	while ( ptr > - 1 && ptr < BVH_STACK_DEPTH ) {

		uint currNodeIndex = stack[ ptr ];
		ptr --;

		// check if we intersect the current bounds
		float boundsHitDistance;
		if (
			! intersectsBVHNodeBounds( rayOrigin, rayDirection, bvh_bvhBounds, currNodeIndex, boundsHitDistance )
			|| boundsHitDistance > triangleDistance
		) {

			continue;

		}

		uvec2 boundsInfo = uTexelFetch1D( bvh_bvhContents, currNodeIndex ).xy;
		bool isLeaf = bool( boundsInfo.x & 0xffff0000u );

		if ( isLeaf ) {

			uint count = boundsInfo.x & 0x0000ffffu;
			uint offset = boundsInfo.y;

			found = intersectTriangles(
				bvh_position, bvh_index, offset, count,
				rayOrigin, rayDirection, triangleDistance,
				faceIndices, faceNormal, barycoord, side, dist
			) || found;

		} else {

			uint leftIndex = currNodeIndex + 1u;
			uint splitAxis = boundsInfo.x & 0x0000ffffu;
			uint rightIndex = currNodeIndex + boundsInfo.y;

			bool leftToRight = rayDirection[ splitAxis ] >= 0.0;
			uint c1 = leftToRight ? leftIndex : rightIndex;
			uint c2 = leftToRight ? rightIndex : leftIndex;

			// set c2 in the stack so we traverse it later. We need to keep track of a pointer in
			// the stack while we traverse. The second pointer added is the one that will be
			// traversed first
			ptr ++;
			stack[ ptr ] = c2;

			ptr ++;
			stack[ ptr ] = c1;

		}

	}

	return found;

}
`;var pp=`
struct BVH {

	usampler2D index;
	sampler2D position;

	sampler2D bvhBounds;
	usampler2D bvhContents;

};
`;var k3=`
	${xh}
	${vh}
`;function Wc(i,e,t=0){if(i.isInterleavedBufferAttribute){let n=i.itemSize;for(let r=0,s=i.count;r<s;r++){let a=r+t;e.setX(a,i.getX(r)),n>=2&&e.setY(a,i.getY(r)),n>=3&&e.setZ(a,i.getZ(r)),n>=4&&e.setW(a,i.getW(r))}}else{let n=e.array,r=n.constructor,s=n.BYTES_PER_ELEMENT*i.itemSize*t;new r(n.buffer,s,i.array.length).set(i.array)}}function gr(i,e=null){let t=i.array.constructor,n=i.normalized,r=i.itemSize,s=e===null?i.count:e;return new mt(new t(r*s),r,n)}function Xi(i,e){if(!i&&!e)return!0;if(!!i!=!!e)return!1;let t=i.count===e.count,n=i.normalized===e.normalized,r=i.array.constructor===e.array.constructor,s=i.itemSize===e.itemSize;return!(!t||!n||!r||!s)}function my(i){let e=i[0].index!==null,t=new Set(Object.keys(i[0].attributes));if(!i[0].getAttribute("position"))throw new Error("StaticGeometryGenerator: position attribute is required.");for(let n=0;n<i.length;++n){let r=i[n],s=0;if(e!==(r.index!==null))throw new Error("StaticGeometryGenerator: All geometries must have compatible attributes; make sure index attribute exists among all geometries, or in none of them.");for(let a in r.attributes){if(!t.has(a))throw new Error('StaticGeometryGenerator: All geometries must have compatible attributes; make sure "'+a+'" attribute exists among all geometries, or in none of them.');s++}if(s!==t.size)throw new Error("StaticGeometryGenerator: All geometries must have the same number of attributes.")}}function gy(i){let e=0;for(let t=0,n=i.length;t<n;t++)e+=i[t].getIndex().count;return e}function xy(i){let e=0;for(let t=0,n=i.length;t<n;t++)e+=i[t].getAttribute("position").count;return e}function vy(i,e,t){i.index&&i.index.count!==e&&i.setIndex(null);let n=i.attributes;for(let r in n)n[r].count!==t&&i.deleteAttribute(r)}function mp(i,e={},t=new Bt){let{useGroups:n=!1,forceUpdate:r=!1,skipAssigningAttributes:s=[],overwriteIndex:a=!0}=e;my(i);let o=i[0].index!==null,c=o?gy(i):-1,u=xy(i);if(vy(t,c,u),n){let h=0;for(let l=0,p=i.length;l<p;l++){let g=i[l],b;o?b=g.getIndex().count:b=g.getAttribute("position").count,t.addGroup(h,b,l),h+=b}}if(o){let h=!1;if(t.index||(t.setIndex(new mt(new Uint32Array(c),1,!1)),h=!0),h||a){let l=0,p=0,g=t.getIndex();for(let b=0,m=i.length;b<m;b++){let d=i[b],_=d.getIndex();if(!(!r&&!h&&s[b]))for(let M=0;M<_.count;++M)g.setX(l+M,_.getX(M)+p);l+=_.count,p+=d.getAttribute("position").count}}}let f=Object.keys(i[0].attributes);for(let h=0,l=f.length;h<l;h++){let p=!1,g=f[h];if(!t.getAttribute(g)){let d=i[0].getAttribute(g);t.setAttribute(g,gr(d,u)),p=!0}let b=0,m=t.getAttribute(g);for(let d=0,_=i.length;d<_;d++){let y=i[d],M=!r&&!p&&s[d],w=y.getAttribute(g);if(!M)if(g==="color"&&m.itemSize!==w.itemSize)for(let A=b,I=w.count;A<I;A++)w.setXYZW(A,m.getX(A),m.getY(A),m.getZ(A),1);else Wc(w,m,b);b+=w.count}}}function gp(i,e,t){let n=i.index,s=i.attributes.position.count,a=n?n.count:s,o=i.groups;o.length===0&&(o=[{count:a,start:0,materialIndex:0}]);let c=i.getAttribute("materialIndex");if(!c||c.count!==s){let f;t.length<=255?f=new Uint8Array(s):f=new Uint16Array(s),c=new mt(f,1,!1),i.deleteAttribute("materialIndex"),i.setAttribute("materialIndex",c)}let u=c.array;for(let f=0;f<o.length;f++){let h=o[f],l=h.start,p=h.count,g=Math.min(p,a-l),b=Array.isArray(e)?e[h.materialIndex]:e,m=t.indexOf(b);for(let d=0;d<g;d++){let _=l+d;n&&(_=n.getX(_)),u[_]=m}}}function xp(i,e){if(!i.index){let t=i.attributes.position.count,n=new Array(t);for(let r=0;r<t;r++)n[r]=r;i.setIndex(n)}if(!i.attributes.normal&&e&&e.includes("normal")&&i.computeVertexNormals(),!i.attributes.uv&&e&&e.includes("uv")){let t=i.attributes.position.count;i.setAttribute("uv",new mt(new Float32Array(t*2),2,!1))}if(!i.attributes.uv2&&e&&e.includes("uv2")){let t=i.attributes.position.count;i.setAttribute("uv2",new mt(new Float32Array(t*2),2,!1))}if(!i.attributes.tangent&&e&&e.includes("tangent"))if(i.attributes.uv&&i.attributes.normal)i.computeTangents();else{let t=i.attributes.position.count;i.setAttribute("tangent",new mt(new Float32Array(t*4),4,!1))}if(!i.attributes.color&&e&&e.includes("color")){let t=i.attributes.position.count,n=new Float32Array(t*4);n.fill(1),i.setAttribute("color",new mt(n,4))}}function gs(i){let e=0;if(i.byteLength!==0){let t=new Uint8Array(i);for(let n=0;n<i.byteLength;n++){let r=t[n];e=(e<<5)-e+r,e|=0}}return e}function vp(i){let e=i.uuid,t=Object.values(i.attributes);i.index&&(t.push(i.index),e+=`index|${i.index.version}`);let n=Object.keys(t).sort();for(let r of n){let s=t[r];e+=`${r}_${s.version}|`}return e}function _p(i){let e=i.skeleton;return e?(e.boneTexture||e.computeBoneTexture(),`${gs(e.boneTexture.image.data.buffer)}_${e.boneTexture.uuid}`):null}var Xc=class{constructor(e=null){this.matrixWorld=new Xe,this.geometryHash=null,this.skeletonHash=null,this.primitiveCount=-1,e!==null&&this.updateFrom(e)}updateFrom(e){let t=e.geometry,n=(t.index?t.index.count:t.attributes.position.count)/3;this.matrixWorld.copy(e.matrixWorld),this.geometryHash=vp(t),this.primitiveCount=n,this.skeletonHash=_p(e)}didChange(e){let t=e.geometry,n=(t.index?t.index.count:t.attributes.position.count)/3;return!(this.matrixWorld.equals(e.matrixWorld)&&this.geometryHash===vp(t)&&this.skeletonHash===_p(e)&&this.primitiveCount===n)}};var xr=new k,vr=new k,_r=new k,yp=new ht,qc=new k,_h=new k,bp=new ht,Sp=new ht,Yc=new Xe,Mp=new Xe;function Tp(i,e,t){let n=i.skeleton,r=i.geometry,s=n.bones,a=n.boneInverses;bp.fromBufferAttribute(r.attributes.skinIndex,e),Sp.fromBufferAttribute(r.attributes.skinWeight,e),Yc.elements.fill(0);for(let o=0;o<4;o++){let c=Sp.getComponent(o);if(c!==0){let u=bp.getComponent(o);Mp.multiplyMatrices(s[u].matrixWorld,a[u]),_y(Yc,Mp,c)}}return Yc.multiply(i.bindMatrix).premultiply(i.bindMatrixInverse),t.transformDirection(Yc),t}function yh(i,e,t,n,r){qc.set(0,0,0);for(let s=0,a=i.length;s<a;s++){let o=e[s],c=i[s];o!==0&&(_h.fromBufferAttribute(c,n),t?qc.addScaledVector(_h,o):qc.addScaledVector(_h.sub(r),o))}r.add(qc)}function _y(i,e,t){let n=i.elements,r=e.elements;for(let s=0,a=r.length;s<a;s++)n[s]+=r[s]*t}function yy(i){let{index:e,attributes:t}=i;if(e)for(let n=0,r=e.count;n<r;n+=3){let s=e.getX(n),a=e.getX(n+2);e.setX(n,a),e.setX(n+2,s)}else for(let n in t){let r=t[n],s=r.itemSize;for(let a=0,o=r.count;a<o;a+=3)for(let c=0;c<s;c++){let u=r.getComponent(a,c),f=r.getComponent(a+2,c);r.setComponent(a,c,f),r.setComponent(a+2,c,u)}}return i}function wp(i,e={},t=new Bt){e={applyWorldTransforms:!0,attributes:[],...e};let n=i.geometry,r=e.applyWorldTransforms,s=e.attributes.includes("normal"),a=e.attributes.includes("tangent"),o=n.attributes,c=t.attributes;for(let _ in t.attributes)(!e.attributes.includes(_)||!(_ in n.attributes))&&t.deleteAttribute(_);!t.index&&n.index&&(t.index=n.index.clone()),c.position||t.setAttribute("position",gr(o.position)),s&&!c.normal&&o.normal&&t.setAttribute("normal",gr(o.normal)),a&&!c.tangent&&o.tangent&&t.setAttribute("tangent",gr(o.tangent)),Xi(n.index,t.index),Xi(o.position,c.position),s&&Xi(o.normal,c.normal),a&&Xi(o.tangent,c.tangent);let u=o.position,f=s?o.normal:null,h=a?o.tangent:null,l=n.morphAttributes.position,p=n.morphAttributes.normal,g=n.morphAttributes.tangent,b=n.morphTargetsRelative,m=i.morphTargetInfluences,d=new et;d.getNormalMatrix(i.matrixWorld),n.index&&t.index.array.set(n.index.array);for(let _=0,y=o.position.count;_<y;_++)xr.fromBufferAttribute(u,_),f&&vr.fromBufferAttribute(f,_),h&&(yp.fromBufferAttribute(h,_),_r.fromBufferAttribute(h,_)),m&&(l&&yh(l,m,b,_,xr),p&&yh(p,m,b,_,vr),g&&yh(g,m,b,_,_r)),i.isSkinnedMesh&&(i.applyBoneTransform(_,xr),f&&Tp(i,_,vr),h&&Tp(i,_,_r)),r&&xr.applyMatrix4(i.matrixWorld),c.position.setXYZ(_,xr.x,xr.y,xr.z),f&&(r&&vr.applyNormalMatrix(d),c.normal.setXYZ(_,vr.x,vr.y,vr.z)),h&&(r&&_r.transformDirection(i.matrixWorld),c.tangent.setXYZW(_,_r.x,_r.y,_r.z,yp.w));for(let _ in e.attributes){let y=e.attributes[_];y==="position"||y==="tangent"||y==="normal"||!(y in o)||(c[y]||t.setAttribute(y,gr(o[y])),Xi(o[y],c[y]),Wc(o[y],c[y]))}return i.matrixWorld.determinant()<0&&yy(t),t}var Zc=class extends Bt{constructor(){super(),this.version=0,this.hash=null,this._diff=new Xc}isCompatible(e,t){let n=e.geometry;for(let r=0;r<t.length;r++){let s=t[r],a=n.attributes[s],o=this.attributes[s];if(a&&!Xi(a,o))return!1}return!0}updateFrom(e,t){let n=this._diff;return n.didChange(e)?(wp(e,t,this),n.updateFrom(e),this.version++,this.hash=`${this.uuid}_${this.version}`,!0):!1}};var Jc=0,bh=1,Sh=2;function by(i,e){for(let t=0,n=i.length;t<n;t++)i[t].traverseVisible(s=>{s.isMesh&&e(s)})}function Sy(i){let e=[];for(let t=0,n=i.length;t<n;t++){let r=i[t];Array.isArray(r.material)?e.push(...r.material):e.push(r.material)}return e}function My(i,e,t){if(i.length===0){e.setIndex(null);let n=e.attributes;for(let r in n)e.deleteAttribute(r);for(let r in t.attributes)e.setAttribute(t.attributes[r],new mt(new Float32Array(0),4,!1))}else mp(i,t,e);for(let n in e.attributes)e.attributes[n].needsUpdate=!0}var $c=class{constructor(e){this.objects=null,this.useGroups=!0,this.applyWorldTransforms=!0,this.generateMissingAttributes=!0,this.overwriteIndex=!0,this.attributes=["position","normal","color","tangent","uv","uv2"],this._intermediateGeometry=new Map,this._geometryMergeSets=new WeakMap,this._mergeOrder=[],this._dummyMesh=null,this.setObjects(e||[])}_getDummyMesh(){if(!this._dummyMesh){let e=new tr,t=new Bt;t.setAttribute("position",new mt(new Float32Array(9),3)),this._dummyMesh=new rn(t,e)}return this._dummyMesh}_getMeshes(){let e=[];return by(this.objects,t=>{e.push(t)}),e.sort((t,n)=>t.uuid>n.uuid?1:t.uuid<n.uuid?-1:0),e.length===0&&e.push(this._getDummyMesh()),e}_updateIntermediateGeometries(){let{_intermediateGeometry:e}=this,t=this._getMeshes(),n=new Set(e.keys()),r={attributes:this.attributes,applyWorldTransforms:this.applyWorldTransforms};for(let s=0,a=t.length;s<a;s++){let o=t[s],c=o.uuid;n.delete(c);let u=e.get(c);(!u||!u.isCompatible(o,this.attributes))&&(u&&u.dispose(),u=new Zc,e.set(c,u)),u.updateFrom(o,r)&&this.generateMissingAttributes&&xp(u,this.attributes)}n.forEach(s=>{e.delete(s)})}setObjects(e){Array.isArray(e)?this.objects=[...e]:this.objects=[e]}generate(e=new Bt){let{useGroups:t,overwriteIndex:n,_intermediateGeometry:r,_geometryMergeSets:s}=this,a=this._getMeshes(),o=[],c=[],u=s.get(e)||[];this._updateIntermediateGeometries();let f=!1;a.length!==u.length&&(f=!0);for(let l=0,p=a.length;l<p;l++){let g=a[l],b=r.get(g.uuid);c.push(b);let m=u[l];!m||m.uuid!==b.uuid?(o.push(!1),f=!0):m.version!==b.version?o.push(!1):o.push(!0)}My(c,e,{useGroups:t,forceUpdate:f,skipAssigningAttributes:o,overwriteIndex:n}),f&&e.dispose(),s.set(e,c.map(l=>({version:l.version,uuid:l.uuid})));let h=Jc;return f?h=Sh:o.includes(!1)&&(h=bh),{changeType:h,materials:Sy(a),geometry:e}}};function Ty(i){let e=new Set;for(let t=0,n=i.length;t<n;t++){let r=i[t];for(let s in r){let a=r[s];a&&a.isTexture&&e.add(a)}}return Array.from(e)}function wy(i){let e=[],t=new Set;for(let r=0,s=i.length;r<s;r++)i[r].traverse(a=>{a.visible&&(a.isRectAreaLight||a.isSpotLight||a.isPointLight||a.isDirectionalLight)&&(e.push(a),a.iesMap&&t.add(a.iesMap))});let n=Array.from(t).sort((r,s)=>r.uuid<s.uuid?1:r.uuid>s.uuid?-1:0);return{lights:e,iesTextures:n}}var Kc=class{get initialized(){return!!this.bvh}constructor(e){this.bvhOptions={},this.attributes=["position","normal","tangent","color","uv","uv2"],this.generateBVH=!0,this.bvh=null,this.geometry=new Bt,this.staticGeometryGenerator=new $c(e),this._bvhWorker=null,this._pendingGenerate=null,this._buildAsync=!1,this._materialUuids=null}setObjects(e){this.staticGeometryGenerator.setObjects(e)}setBVHWorker(e){this._bvhWorker=e}async generateAsync(e=null){if(!this._bvhWorker)throw new Error('PathTracingSceneGenerator: "setBVHWorker" must be called before "generateAsync" can be called.');if(this.bvh instanceof Promise)return this._pendingGenerate||(this._pendingGenerate=new Promise(async()=>(await this.bvh,this._pendingGenerate=null,this.generateAsync(e)))),this._pendingGenerate;{this._buildAsync=!0;let t=this.generate(e);return this._buildAsync=!1,t.bvh=this.bvh=await t.bvh,t}}generate(e=null){let{staticGeometryGenerator:t,geometry:n,attributes:r}=this,s=t.objects;t.attributes=r,s.forEach(l=>{l.traverse(p=>{p.isSkinnedMesh&&p.skeleton&&p.skeleton.update()})});let a=t.generate(n),o=a.materials,c=a.changeType!==Jc||this._materialUuids===null||this._materialUuids.length!==length;if(!c){for(let l=0,p=o.length;l<p;l++)if(o[l].uuid!==this._materialUuids[l]){c=!0;break}}let u=Ty(o),{lights:f,iesTextures:h}=wy(s);if(c&&(gp(n,o,o),this._materialUuids=o.map(l=>l.uuid)),this.generateBVH){if(this.bvh instanceof Promise)throw new Error("PathTracingSceneGenerator: BVH is already building asynchronously.");if(a.changeType===Sh){let l={strategy:2,maxLeafTris:1,indirect:!0,onProgress:e,...this.bvhOptions};this._buildAsync?this.bvh=this._bvhWorker.generate(n,l):this.bvh=new Vc(n,l)}else a.changeType===bh&&this.bvh.refit()}return{bvhChanged:a.changeType!==Jc,bvh:this.bvh,needsMaterialIndexUpdate:c,lights:f,iesTextures:h,geometry:n,materials:o,textures:u,objects:s}}};var Ay=new pi(-1,1,1,-1,0,1),Mh=class extends Bt{constructor(){super(),this.setAttribute("position",new tn([-1,3,0,-1,-1,0,3,-1,0],3)),this.setAttribute("uv",new tn([0,2,0,0,2,0],2))}},Ey=new Mh,Pn=class{constructor(e){this._mesh=new rn(Ey,e)}dispose(){this._mesh.geometry.dispose()}render(e){e.render(this._mesh,Ay)}get material(){return this._mesh.material}set material(e){this._mesh.material=e}};var qi=class extends Xt{set needsUpdate(e){super.needsUpdate=!0,this.dispatchEvent({type:"recompilation"})}constructor(e){super(e);for(let t in this.uniforms)Object.defineProperty(this,t,{get(){return this.uniforms[t].value},set(n){this.uniforms[t].value=n}})}setDefine(e,t=void 0){if(t==null){if(e in this.defines)return delete this.defines[e],this.needsUpdate=!0,!0}else if(this.defines[e]!==t)return this.defines[e]=t,this.needsUpdate=!0,!0;return!1}};var Qc=class extends qi{constructor(e){super({blending:$t,uniforms:{target1:{value:null},target2:{value:null},opacity:{value:1}},vertexShader:`

				varying vec2 vUv;

				void main() {

					vUv = uv;
					gl_Position = projectionMatrix * modelViewMatrix * vec4( position, 1.0 );

				}`,fragmentShader:`

				uniform float opacity;

				uniform sampler2D target1;
				uniform sampler2D target2;

				varying vec2 vUv;

				void main() {

					vec4 color1 = texture2D( target1, vUv );
					vec4 color2 = texture2D( target2, vUv );

					float invOpacity = 1.0 - opacity;
					float totalAlpha = color1.a * invOpacity + color2.a * opacity;

					if ( color1.a != 0.0 || color2.a != 0.0 ) {

						gl_FragColor.rgb = color1.rgb * ( invOpacity * color1.a / totalAlpha ) + color2.rgb * ( opacity * color2.a / totalAlpha );
						gl_FragColor.a = totalAlpha;

					} else {

						gl_FragColor = vec4( 0.0 );

					}

				}`}),this.setValues(e)}};function jc(i=1){let e="uint";return i>1&&(e="uvec"+i),`
		${e} sobolReverseBits( ${e} x ) {

			x = ( ( ( x & 0xaaaaaaaau ) >> 1 ) | ( ( x & 0x55555555u ) << 1 ) );
			x = ( ( ( x & 0xccccccccu ) >> 2 ) | ( ( x & 0x33333333u ) << 2 ) );
			x = ( ( ( x & 0xf0f0f0f0u ) >> 4 ) | ( ( x & 0x0f0f0f0fu ) << 4 ) );
			x = ( ( ( x & 0xff00ff00u ) >> 8 ) | ( ( x & 0x00ff00ffu ) << 8 ) );
			return ( ( x >> 16 ) | ( x << 16 ) );

		}

		${e} sobolHashCombine( uint seed, ${e} v ) {

			return seed ^ ( v + ${e}( ( seed << 6 ) + ( seed >> 2 ) ) );

		}

		${e} sobolLaineKarrasPermutation( ${e} x, ${e} seed ) {

			x += seed;
			x ^= x * 0x6c50b47cu;
			x ^= x * 0xb82f1e52u;
			x ^= x * 0xc7afe638u;
			x ^= x * 0x8d22f6e6u;
			return x;

		}

		${e} nestedUniformScrambleBase2( ${e} x, ${e} seed ) {

			x = sobolLaineKarrasPermutation( x, seed );
			x = sobolReverseBits( x );
			return x;

		}
	`}function el(i=1){let e="uint",t="float",n="",r=".r",s="1u";return i>1&&(e="uvec"+i,t="vec"+i,n=i+"",i===2?(r=".rg",s="uvec2( 1u, 2u )"):i===3?(r=".rgb",s="uvec3( 1u, 2u, 3u )"):(r="",s="uvec4( 1u, 2u, 3u, 4u )")),`

		${t} sobol${n}( int effect ) {

			uint seed = sobolGetSeed( sobolBounceIndex, uint( effect ) );
			uint index = sobolPathIndex;

			uint shuffle_seed = sobolHashCombine( seed, 0u );
			uint shuffled_index = nestedUniformScrambleBase2( sobolReverseBits( index ), shuffle_seed );
			${t} sobol_pt = sobolGetTexturePoint( shuffled_index )${r};
			${e} result = ${e}( sobol_pt * 16777216.0 );

			${e} seed2 = sobolHashCombine( seed, ${s} );
			result = nestedUniformScrambleBase2( result, seed2 );

			return SOBOL_FACTOR * ${t}( result >> 8 );

		}
	`}var tl=`

	// Utils
	const float SOBOL_FACTOR = 1.0 / 16777216.0;
	const uint SOBOL_MAX_POINTS = 256u * 256u;

	${jc(1)}
	${jc(2)}
	${jc(3)}
	${jc(4)}

	uint sobolHash( uint x ) {

		// finalizer from murmurhash3
		x ^= x >> 16;
		x *= 0x85ebca6bu;
		x ^= x >> 13;
		x *= 0xc2b2ae35u;
		x ^= x >> 16;
		return x;

	}

`,Ap=`

	const uint SOBOL_DIRECTIONS_1[ 32 ] = uint[ 32 ](
		0x80000000u, 0xc0000000u, 0xa0000000u, 0xf0000000u,
		0x88000000u, 0xcc000000u, 0xaa000000u, 0xff000000u,
		0x80800000u, 0xc0c00000u, 0xa0a00000u, 0xf0f00000u,
		0x88880000u, 0xcccc0000u, 0xaaaa0000u, 0xffff0000u,
		0x80008000u, 0xc000c000u, 0xa000a000u, 0xf000f000u,
		0x88008800u, 0xcc00cc00u, 0xaa00aa00u, 0xff00ff00u,
		0x80808080u, 0xc0c0c0c0u, 0xa0a0a0a0u, 0xf0f0f0f0u,
		0x88888888u, 0xccccccccu, 0xaaaaaaaau, 0xffffffffu
	);

	const uint SOBOL_DIRECTIONS_2[ 32 ] = uint[ 32 ](
		0x80000000u, 0xc0000000u, 0x60000000u, 0x90000000u,
		0xe8000000u, 0x5c000000u, 0x8e000000u, 0xc5000000u,
		0x68800000u, 0x9cc00000u, 0xee600000u, 0x55900000u,
		0x80680000u, 0xc09c0000u, 0x60ee0000u, 0x90550000u,
		0xe8808000u, 0x5cc0c000u, 0x8e606000u, 0xc5909000u,
		0x6868e800u, 0x9c9c5c00u, 0xeeee8e00u, 0x5555c500u,
		0x8000e880u, 0xc0005cc0u, 0x60008e60u, 0x9000c590u,
		0xe8006868u, 0x5c009c9cu, 0x8e00eeeeu, 0xc5005555u
	);

	const uint SOBOL_DIRECTIONS_3[ 32 ] = uint[ 32 ](
		0x80000000u, 0xc0000000u, 0x20000000u, 0x50000000u,
		0xf8000000u, 0x74000000u, 0xa2000000u, 0x93000000u,
		0xd8800000u, 0x25400000u, 0x59e00000u, 0xe6d00000u,
		0x78080000u, 0xb40c0000u, 0x82020000u, 0xc3050000u,
		0x208f8000u, 0x51474000u, 0xfbea2000u, 0x75d93000u,
		0xa0858800u, 0x914e5400u, 0xdbe79e00u, 0x25db6d00u,
		0x58800080u, 0xe54000c0u, 0x79e00020u, 0xb6d00050u,
		0x800800f8u, 0xc00c0074u, 0x200200a2u, 0x50050093u
	);

	const uint SOBOL_DIRECTIONS_4[ 32 ] = uint[ 32 ](
		0x80000000u, 0x40000000u, 0x20000000u, 0xb0000000u,
		0xf8000000u, 0xdc000000u, 0x7a000000u, 0x9d000000u,
		0x5a800000u, 0x2fc00000u, 0xa1600000u, 0xf0b00000u,
		0xda880000u, 0x6fc40000u, 0x81620000u, 0x40bb0000u,
		0x22878000u, 0xb3c9c000u, 0xfb65a000u, 0xddb2d000u,
		0x78022800u, 0x9c0b3c00u, 0x5a0fb600u, 0x2d0ddb00u,
		0xa2878080u, 0xf3c9c040u, 0xdb65a020u, 0x6db2d0b0u,
		0x800228f8u, 0x400b3cdcu, 0x200fb67au, 0xb00ddb9du
	);

	uint getMaskedSobol( uint index, uint directions[ 32 ] ) {

		uint X = 0u;
		for ( int bit = 0; bit < 32; bit ++ ) {

			uint mask = ( index >> bit ) & 1u;
			X ^= mask * directions[ bit ];

		}
		return X;

	}

	vec4 generateSobolPoint( uint index ) {

		if ( index >= SOBOL_MAX_POINTS ) {

			return vec4( 0.0 );

		}

		// NOTE: this sobol "direction" is also available but we can't write out 5 components
		// uint x = index & 0x00ffffffu;
		uint x = sobolReverseBits( getMaskedSobol( index, SOBOL_DIRECTIONS_1 ) ) & 0x00ffffffu;
		uint y = sobolReverseBits( getMaskedSobol( index, SOBOL_DIRECTIONS_2 ) ) & 0x00ffffffu;
		uint z = sobolReverseBits( getMaskedSobol( index, SOBOL_DIRECTIONS_3 ) ) & 0x00ffffffu;
		uint w = sobolReverseBits( getMaskedSobol( index, SOBOL_DIRECTIONS_4 ) ) & 0x00ffffffu;

		return vec4( x, y, z, w ) * SOBOL_FACTOR;

	}

`,Ep=`

	// Seeds
	uniform sampler2D sobolTexture;
	uint sobolPixelIndex = 0u;
	uint sobolPathIndex = 0u;
	uint sobolBounceIndex = 0u;

	uint sobolGetSeed( uint bounce, uint effect ) {

		return sobolHash(
			sobolHashCombine(
				sobolHashCombine(
					sobolHash( bounce ),
					sobolPixelIndex
				),
				effect
			)
		);

	}

	vec4 sobolGetTexturePoint( uint index ) {

		if ( index >= SOBOL_MAX_POINTS ) {

			index = index % SOBOL_MAX_POINTS;

		}

		uvec2 dim = uvec2( textureSize( sobolTexture, 0 ).xy );
		uint y = index / dim.x;
		uint x = index - y * dim.x;
		vec2 uv = vec2( x, y ) / vec2( dim );
		return texture( sobolTexture, uv );

	}

	${el(1)}
	${el(2)}
	${el(3)}
	${el(4)}

`;var Th=class extends qi{constructor(){super({blending:$t,uniforms:{resolution:{value:new Le}},vertexShader:`

				varying vec2 vUv;
				void main() {

					vUv = uv;
					gl_Position = projectionMatrix * modelViewMatrix * vec4( position, 1.0 );

				}
			`,fragmentShader:`

				${tl}
				${Ap}

				varying vec2 vUv;
				uniform vec2 resolution;
				void main() {

					uint index = uint( gl_FragCoord.y ) * uint( resolution.x ) + uint( gl_FragCoord.x );
					gl_FragColor = generateSobolPoint( index );

				}
			`})}},nl=class{generate(e,t=256){let n=new Yt(t,t,{type:qe,format:He,minFilter:je,magFilter:je,generateMipmaps:!1}),r=e.getRenderTarget();e.setRenderTarget(n);let s=new Pn(new Th);return s.material.resolution.set(t,t),s.render(e),e.setRenderTarget(r),s.dispose(),n}};var il=class extends kt{set bokehSize(e){this.fStop=this.getFocalLength()/e}get bokehSize(){return this.getFocalLength()/this.fStop}constructor(...e){super(...e),this.fStop=1.4,this.apertureBlades=0,this.apertureRotation=0,this.focusDistance=25,this.anamorphicRatio=1}copy(e,t){return super.copy(e,t),this.fStop=e.fStop,this.apertureBlades=e.apertureBlades,this.apertureRotation=e.apertureRotation,this.focusDistance=e.focusDistance,this.anamorphicRatio=e.anamorphicRatio,this}};var rl=class{constructor(){this.bokehSize=0,this.apertureBlades=0,this.apertureRotation=0,this.focusDistance=10,this.anamorphicRatio=1}updateFrom(e){e instanceof il?(this.bokehSize=e.bokehSize,this.apertureBlades=e.apertureBlades,this.apertureRotation=e.apertureRotation,this.focusDistance=e.focusDistance,this.anamorphicRatio=e.anamorphicRatio):(this.bokehSize=0,this.apertureRotation=0,this.apertureBlades=0,this.focusDistance=10,this.anamorphicRatio=1)}};function sl(i){let e=new Uint16Array(i.length);for(let t=0,n=i.length;t<n;++t)e[t]=Ot.toHalfFloat(i[t]);return e}function Cp(i,e,t=0,n=i.length){let r=t,s=t+n-1;for(;r<s;){let a=r+s>>1;i[a]<e?r=a+1:s=a}return r-t}function Cy(i,e,t){return .2126*i+.7152*e+.0722*t}function Ry(i,e=_t){let t=i.clone();t.source=new Ci({...t.image});let{width:n,height:r,data:s}=t.image,a=s;if(t.type!==e){e===_t?a=new Uint16Array(s.length):a=new Float32Array(s.length);let o;s instanceof Int8Array||s instanceof Int16Array||s instanceof Int32Array?o=2**(8*s.BYTES_PER_ELEMENT-1)-1:o=2**(8*s.BYTES_PER_ELEMENT)-1;for(let c=0,u=s.length;c<u;c++){let f=s[c];t.type===_t&&(f=Ot.fromHalfFloat(s[c])),t.type!==qe&&t.type!==_t&&(f/=o),e===_t&&(a[c]=Ot.toHalfFloat(f))}t.image.data=a,t.type=e}if(t.flipY){let o=a;a=a.slice();for(let c=0;c<r;c++)for(let u=0;u<n;u++){let f=r-c-1,h=4*(c*n+u),l=4*(f*n+u);a[l+0]=o[h+0],a[l+1]=o[h+1],a[l+2]=o[h+2],a[l+3]=o[h+3]}t.flipY=!1,t.image.data=a}return t}var al=class{constructor(){let e=new St(sl(new Float32Array([0,0,0,0])),1,1);e.type=_t,e.format=He,e.minFilter=ft,e.magFilter=ft,e.wrapS=hn,e.wrapT=hn,e.generateMipmaps=!1,e.needsUpdate=!0;let t=new St(sl(new Float32Array([0,1])),1,2);t.type=_t,t.format=vn,t.minFilter=ft,t.magFilter=ft,t.generateMipmaps=!1,t.needsUpdate=!0;let n=new St(sl(new Float32Array([0,0,1,1])),2,2);n.type=_t,n.format=vn,n.minFilter=ft,n.magFilter=ft,n.generateMipmaps=!1,n.needsUpdate=!0,this.map=e,this.marginalWeights=t,this.conditionalWeights=n,this.totalSum=0}dispose(){this.marginalWeights.dispose(),this.conditionalWeights.dispose(),this.map.dispose()}updateFrom(e){let t=Ry(e);t.wrapS=hn,t.wrapT=Lt;let{width:n,height:r,data:s}=t.image,a=new Float32Array(n*r),o=new Float32Array(n*r),c=new Float32Array(r),u=new Float32Array(r),f=0,h=0;for(let m=0;m<r;m++){let d=0;for(let _=0;_<n;_++){let y=m*n+_,M=Ot.fromHalfFloat(s[4*y+0]),w=Ot.fromHalfFloat(s[4*y+1]),A=Ot.fromHalfFloat(s[4*y+2]),I=Cy(M,w,A);d+=I,f+=I,a[y]=I,o[y]=d}if(d!==0)for(let _=m*n,y=m*n+n;_<y;_++)a[_]/=d,o[_]/=d;h+=d,c[m]=d,u[m]=h}if(h!==0)for(let m=0,d=c.length;m<d;m++)c[m]/=h,u[m]/=h;let l=new Uint16Array(r),p=new Uint16Array(n*r);for(let m=0;m<r;m++){let d=(m+1)/r,_=Cp(u,d);l[m]=Ot.toHalfFloat((_+.5)/r)}for(let m=0;m<r;m++)for(let d=0;d<n;d++){let _=m*n+d,y=(d+1)/n,M=Cp(o,y,m*n,n);p[_]=Ot.toHalfFloat((M+.5)/n)}this.dispose();let{marginalWeights:g,conditionalWeights:b}=this;g.image={width:r,height:1,data:l},g.needsUpdate=!0,b.image={width:n,height:r,data:p},b.needsUpdate=!0,this.totalSum=f,this.map=t}};var wh=6,Iy=0,Py=1,Dy=2,Fy=3,Ly=4,Zn=new k,wn=new k,Rp=new Xe,xs=new Wn,Ip=new k,vs=new k,Ny=new k(0,1,0),ol=class{constructor(){let e=new St(new Float32Array(4),1,1);e.format=He,e.type=qe,e.wrapS=Lt,e.wrapT=Lt,e.generateMipmaps=!1,e.minFilter=je,e.magFilter=je,this.tex=e,this.count=0}updateFrom(e,t=[]){let n=this.tex,r=Math.max(e.length*wh,1),s=Math.ceil(Math.sqrt(r));n.image.width!==s&&(n.dispose(),n.image.data=new Float32Array(s*s*4),n.image.width=s,n.image.height=s);let a=n.image.data;for(let c=0,u=e.length;c<u;c++){let f=e[c],h=c*wh*4,l=0;for(let g=0;g<wh*4;g++)a[h+g]=0;f.getWorldPosition(wn),a[h+l++]=wn.x,a[h+l++]=wn.y,a[h+l++]=wn.z;let p=Iy;if(f.isRectAreaLight&&f.isCircular?p=Py:f.isSpotLight?p=Dy:f.isDirectionalLight?p=Fy:f.isPointLight&&(p=Ly),a[h+l++]=p,a[h+l++]=f.color.r,a[h+l++]=f.color.g,a[h+l++]=f.color.b,a[h+l++]=f.intensity,f.getWorldQuaternion(xs),f.isRectAreaLight)Zn.set(f.width,0,0).applyQuaternion(xs),a[h+l++]=Zn.x,a[h+l++]=Zn.y,a[h+l++]=Zn.z,l++,wn.set(0,f.height,0).applyQuaternion(xs),a[h+l++]=wn.x,a[h+l++]=wn.y,a[h+l++]=wn.z,a[h+l++]=Zn.cross(wn).length()*(f.isCircular?Math.PI/4:1);else if(f.isSpotLight){let g=f.radius||0;Ip.setFromMatrixPosition(f.matrixWorld),vs.setFromMatrixPosition(f.target.matrixWorld),Rp.lookAt(Ip,vs,Ny),xs.setFromRotationMatrix(Rp),Zn.set(1,0,0).applyQuaternion(xs),a[h+l++]=Zn.x,a[h+l++]=Zn.y,a[h+l++]=Zn.z,l++,wn.set(0,1,0).applyQuaternion(xs),a[h+l++]=wn.x,a[h+l++]=wn.y,a[h+l++]=wn.z,a[h+l++]=Math.PI*g*g,a[h+l++]=g,a[h+l++]=f.decay,a[h+l++]=f.distance,a[h+l++]=Math.cos(f.angle),a[h+l++]=Math.cos(f.angle*(1-f.penumbra)),a[h+l++]=f.iesMap?t.indexOf(f.iesMap):-1}else if(f.isPointLight){let g=Zn.setFromMatrixPosition(f.matrixWorld);a[h+l++]=g.x,a[h+l++]=g.y,a[h+l++]=g.z,l++,l+=4,l+=1,a[h+l++]=f.decay,a[h+l++]=f.distance}else if(f.isDirectionalLight){let g=Zn.setFromMatrixPosition(f.matrixWorld),b=wn.setFromMatrixPosition(f.target.matrixWorld);vs.subVectors(g,b).normalize(),a[h+l++]=vs.x,a[h+l++]=vs.y,a[h+l++]=vs.z}}this.count=e.length;let o=gs(a.buffer);return this.hash!==o?(this.hash=o,n.needsUpdate=!0,!0):!1}};function Pp(i,e,t,n,r){if(e>n)throw new Error;let s=i.length/e,a=i.constructor.BYTES_PER_ELEMENT*8,o=1;switch(i.constructor){case Uint8Array:case Uint16Array:case Uint32Array:o=2**a-1;break;case Int8Array:case Int16Array:case Int32Array:o=2**(a-1)-1;break}for(let c=0;c<s;c++){let u=4*c,f=e*c;for(let h=0;h<n;h++)t[r+u+h]=e>=h+1?i[f+h]/o:0}}var cl=class extends Ri{constructor(){super(),this._textures=[],this.type=qe,this.format=He,this.internalFormat="RGBA32F"}updateAttribute(e,t){let n=this._textures[e];n.updateFrom(t);let r=n.image,s=this.image;if(r.width!==s.width||r.height!==s.height)throw new Error("FloatAttributeTextureArray: Attribute must be the same dimensions when updating single layer.");let{width:a,height:o,data:c}=s,f=a*o*4*e,h=t.itemSize;h===3&&(h=4),Pp(n.image.data,h,c,4,f),this.dispose(),this.needsUpdate=!0}setAttributes(e){let t=e[0].count,n=e.length;for(let h=0,l=n;h<l;h++)if(e[h].count!==t)throw new Error("FloatAttributeTextureArray: All attributes must have the same item count.");let r=this._textures;for(;r.length<n;){let h=new ms;r.push(h)}for(;r.length>n;)r.pop();for(let h=0,l=n;h<l;h++)r[h].updateFrom(e[h]);let a=r[0].image,o=this.image;(a.width!==o.width||a.height!==o.height||a.depth!==n)&&(o.width=a.width,o.height=a.height,o.depth=n,o.data=new Float32Array(o.width*o.height*o.depth*4));let{data:c,width:u,height:f}=o;for(let h=0,l=n;h<l;h++){let p=r[h],b=u*f*4*h,m=e[h].itemSize;m===3&&(m=4),Pp(p.image.data,m,c,4,b)}this.dispose(),this.needsUpdate=!0}};var ll=class extends cl{updateNormalAttribute(e){this.updateAttribute(0,e)}updateTangentAttribute(e){this.updateAttribute(1,e)}updateUvAttribute(e){this.updateAttribute(2,e)}updateColorAttribute(e){this.updateAttribute(3,e)}updateFrom(e,t,n,r){this.setAttributes([e,t,n,r])}};function Ah(i,e){return i.uuid<e.uuid?1:i.uuid>e.uuid?-1:0}function ul(i){return`${i.source.uuid}:${i.colorSpace}`}function Uy(i){let e=new Set,t=[];for(let n=0,r=i.length;n<r;n++){let s=i[n],a=ul(s);e.has(a)||(e.add(a),t.push(s))}return t}function Dp(i){let e=i.map(n=>n.iesMap||null).filter(n=>n),t=new Set(e);return Array.from(t).sort(Ah)}function Fp(i){let e=new Set;for(let n=0,r=i.length;n<r;n++){let s=i[n];for(let a in s){let o=s[a];o&&o.isTexture&&e.add(o)}}let t=Array.from(e);return Uy(t).sort(Ah)}function Lp(i){let e=[];return i.traverse(t=>{t.visible&&(t.isRectAreaLight||t.isSpotLight||t.isPointLight||t.isDirectionalLight)&&e.push(t)}),e.sort(Ah)}var fl=47,Np=fl*4,Eh=class{constructor(){this._features={}}isUsed(e){return e in this._features}setUsed(e,t=!0){t===!1?delete this._features[e]:this._features[e]=!0}reset(){this._features={}}},hl=class extends St{constructor(){super(new Float32Array(4),1,1),this.format=He,this.type=qe,this.wrapS=Lt,this.wrapT=Lt,this.minFilter=je,this.magFilter=je,this.generateMipmaps=!1,this.features=new Eh}updateFrom(e,t){function n(g,b,m=-1){if(b in g&&g[b]){let d=ul(g[b]);return h[d]}else return m}function r(g,b,m){return b in g?g[b]:m}function s(g,b,m,d){let _=g[b]&&g[b].isTexture?g[b]:null;if(_){_.matrixAutoUpdate&&_.updateMatrix();let y=_.matrix.elements,M=0;m[d+M++]=y[0],m[d+M++]=y[3],m[d+M++]=y[6],M++,m[d+M++]=y[1],m[d+M++]=y[4],m[d+M++]=y[7],M++}return 8}let a=0,o=e.length*fl,c=Math.ceil(Math.sqrt(o))||1,{image:u,features:f}=this,h={};for(let g=0,b=t.length;g<b;g++)h[ul(t[g])]=g;u.width!==c&&(this.dispose(),u.data=new Float32Array(c*c*4),u.width=c,u.height=c);let l=u.data;f.reset();for(let g=0,b=e.length;g<b;g++){let m=e[g];if(m.isFogVolumeMaterial){f.setUsed("FOG");for(let y=0;y<Np;y++)l[a+y]=0;l[a+0+0]=m.color.r,l[a+0+1]=m.color.g,l[a+0+2]=m.color.b,l[a+8+3]=r(m,"emissiveIntensity",0),l[a+12+0]=m.emissive.r,l[a+12+1]=m.emissive.g,l[a+12+2]=m.emissive.b,l[a+52+1]=m.density,l[a+52+3]=0,l[a+56+2]=4,a+=Np;continue}l[a++]=m.color.r,l[a++]=m.color.g,l[a++]=m.color.b,l[a++]=n(m,"map"),l[a++]=r(m,"metalness",0),l[a++]=n(m,"metalnessMap"),l[a++]=r(m,"roughness",0),l[a++]=n(m,"roughnessMap"),l[a++]=r(m,"ior",1.5),l[a++]=r(m,"transmission",0),l[a++]=n(m,"transmissionMap"),l[a++]=r(m,"emissiveIntensity",0),"emissive"in m?(l[a++]=m.emissive.r,l[a++]=m.emissive.g,l[a++]=m.emissive.b):(l[a++]=0,l[a++]=0,l[a++]=0),l[a++]=n(m,"emissiveMap"),l[a++]=n(m,"normalMap"),"normalScale"in m?(l[a++]=m.normalScale.x,l[a++]=m.normalScale.y):(l[a++]=1,l[a++]=1),l[a++]=r(m,"clearcoat",0),l[a++]=n(m,"clearcoatMap"),l[a++]=r(m,"clearcoatRoughness",0),l[a++]=n(m,"clearcoatRoughnessMap"),l[a++]=n(m,"clearcoatNormalMap"),"clearcoatNormalScale"in m?(l[a++]=m.clearcoatNormalScale.x,l[a++]=m.clearcoatNormalScale.y):(l[a++]=1,l[a++]=1),a++,l[a++]=r(m,"sheen",0),"sheenColor"in m?(l[a++]=m.sheenColor.r,l[a++]=m.sheenColor.g,l[a++]=m.sheenColor.b):(l[a++]=0,l[a++]=0,l[a++]=0),l[a++]=n(m,"sheenColorMap"),l[a++]=r(m,"sheenRoughness",0),l[a++]=n(m,"sheenRoughnessMap"),l[a++]=n(m,"iridescenceMap"),l[a++]=n(m,"iridescenceThicknessMap"),l[a++]=r(m,"iridescence",0),l[a++]=r(m,"iridescenceIOR",1.3);let d=r(m,"iridescenceThicknessRange",[100,400]);l[a++]=d[0],l[a++]=d[1],"specularColor"in m?(l[a++]=m.specularColor.r,l[a++]=m.specularColor.g,l[a++]=m.specularColor.b):(l[a++]=1,l[a++]=1,l[a++]=1),l[a++]=n(m,"specularColorMap"),l[a++]=r(m,"specularIntensity",1),l[a++]=n(m,"specularIntensityMap");let _=r(m,"thickness",0)===0&&r(m,"attenuationDistance",1/0)===1/0;if(l[a++]=Number(_),a++,"attenuationColor"in m?(l[a++]=m.attenuationColor.r,l[a++]=m.attenuationColor.g,l[a++]=m.attenuationColor.b):(l[a++]=1,l[a++]=1,l[a++]=1),l[a++]=r(m,"attenuationDistance",1/0),l[a++]=n(m,"alphaMap"),l[a++]=m.opacity,l[a++]=m.alphaTest,!_&&m.transmission>0)l[a++]=0;else switch(m.side){case Mn:l[a++]=1;break;case Zt:l[a++]=-1;break;case fn:l[a++]=0;break}l[a++]=Number(r(m,"matte",!1)),l[a++]=Number(r(m,"castShadow",!0)),l[a++]=Number(m.vertexColors)|Number(m.flatShading)<<1,l[a++]=Number(m.transparent),a+=s(m,"map",l,a),a+=s(m,"metalnessMap",l,a),a+=s(m,"roughnessMap",l,a),a+=s(m,"transmissionMap",l,a),a+=s(m,"emissiveMap",l,a),a+=s(m,"normalMap",l,a),a+=s(m,"clearcoatMap",l,a),a+=s(m,"clearcoatNormalMap",l,a),a+=s(m,"clearcoatRoughnessMap",l,a),a+=s(m,"sheenColorMap",l,a),a+=s(m,"sheenRoughnessMap",l,a),a+=s(m,"iridescenceMap",l,a),a+=s(m,"iridescenceThicknessMap",l,a),a+=s(m,"specularColorMap",l,a),a+=s(m,"specularIntensityMap",l,a),a+=s(m,"alphaMap",l,a)}let p=gs(l.buffer);return this.hash!==p?(this.hash=p,this.needsUpdate=!0,!0):!1}};var Up=new Ye;function By(i){return i?`${i.uuid}:${i.version}`:null}function Oy(i,e){for(let t in e)t in i&&(i[t]=e[t])}var Ta=class extends Os{constructor(e,t,n){let r={format:He,type:dn,minFilter:ft,magFilter:ft,wrapS:hn,wrapT:hn,generateMipmaps:!1,...n};super(e,t,1,r),Oy(this.texture,r),this.texture.setTextures=(...a)=>{this.setTextures(...a)},this.hashes=[null];let s=new Pn(new Ch);this.fsQuad=s}setTextures(e,t,n=this.width,r=this.height){let s=e.getRenderTarget(),a=e.toneMapping,o=e.getClearAlpha();e.getClearColor(Up);let c=t.length||1;(n!==this.width||r!==this.height||this.depth!==c)&&(this.setSize(n,r,c),this.hashes=new Array(c).fill(null)),e.setClearColor(0,0),e.toneMapping=qn;let u=this.fsQuad,f=this.hashes,h=!1;for(let l=0,p=c;l<p;l++){let g=t[l],b=By(g);g&&(f[l]!==b||g.isWebGLRenderTarget)&&(g.matrixAutoUpdate=!1,g.matrix.identity(),u.material.map=g,e.setRenderTarget(this,l),u.render(e),g.updateMatrix(),g.matrixAutoUpdate=!0,f[l]=b,h=!0)}return u.material.map=null,e.setClearColor(Up,o),e.setRenderTarget(s),e.toneMapping=a,h}dispose(){super.dispose(),this.fsQuad.dispose()}},Ch=class extends Xt{get map(){return this.uniforms.map.value}set map(e){this.uniforms.map.value=e}constructor(){super({uniforms:{map:{value:null}},vertexShader:`
				varying vec2 vUv;
				void main() {

					vUv = uv;
					gl_Position = projectionMatrix * modelViewMatrix * vec4( position, 1.0 );

				}
			`,fragmentShader:`
				uniform sampler2D map;
				varying vec2 vUv;
				void main() {

					gl_FragColor = texture2D( map, vUv );

				}
			`})}};function zy(i,e=Math.random()){for(let t=i.length-1;t>0;t--){let n=Math.floor(e()*(t+1)),r=i[t];i[t]=i[n],i[n]=r}return i}var dl=class{constructor(e,t,n=Math.random){let r=e**t,s=new Uint16Array(r),a=r;for(let o=0;o<r;o++)s[o]=o;this.samples=new Float32Array(t),this.strataCount=e,this.reset=function(){for(let o=0;o<r;o++)s[o]=o;a=0},this.reshuffle=function(){a=0},this.next=function(){let{samples:o}=this;a>=s.length&&(zy(s,n),this.reshuffle());let c=s[a++];for(let u=0;u<t;u++)o[u]=(c%e+n())/e,c=Math.floor(c/e);return o}}};var pl=class{constructor(e,t,n=Math.random){let r=0;for(let c of t)r+=c;let s=new Float32Array(r),a=[],o=0;for(let c of t){let u=new dl(e,c,n);u.samples=new Float32Array(s.buffer,o,u.samples.length),o+=u.samples.length*4,a.push(u)}this.samples=s,this.strataCount=e,this.next=function(){for(let c of a)c.next();return s},this.reshuffle=function(){for(let c of a)c.reshuffle()},this.reset=function(){for(let c of a)c.reset()}}};var Rh=class{constructor(e=0){this.m=2147483648,this.a=1103515245,this.c=12345,this.seed=e}nextInt(){return this.seed=(this.a*this.seed+this.c)%this.m,this.seed}nextFloat(){return this.nextInt()/(this.m-1)}},ml=class extends St{constructor(e=1,t=1,n=8){super(new Float32Array(1),1,1,He,qe),this.minFilter=je,this.magFilter=je,this.strata=n,this.sampler=null,this.generator=new Rh,this.stableNoise=!1,this.random=()=>this.stableNoise?this.generator.nextFloat():Math.random(),this.init(e,t,n)}init(e=this.image.height,t=this.image.width,n=this.strata){let{image:r}=this;if(r.width===t&&r.height===e&&this.sampler!==null)return;let s=new Array(e*t).fill(4),a=new pl(n,s,this.random);r.width=t,r.height=e,r.data=a.samples,this.sampler=a,this.dispose(),this.next()}next(){this.sampler.next(),this.needsUpdate=!0}reset(){this.sampler.reset(),this.generator.seed=0}};function Bp(i,e=Math.random){for(let t=i.length-1;t>0;t--){let n=~~((e()-1e-6)*t),r=i[t];i[t]=i[n],i[n]=r}}function Op(i,e){i.fill(0);for(let t=0;t<e;t++)i[t]=1}var wa=class{constructor(e){this.count=0,this.size=-1,this.sigma=-1,this.radius=-1,this.lookupTable=null,this.score=null,this.binaryPattern=null,this.resize(e),this.setSigma(1.5)}findVoid(){let{score:e,binaryPattern:t}=this,n=1/0,r=-1;for(let s=0,a=t.length;s<a;s++){if(t[s]!==0)continue;let o=e[s];o<n&&(n=o,r=s)}return r}findCluster(){let{score:e,binaryPattern:t}=this,n=-1/0,r=-1;for(let s=0,a=t.length;s<a;s++){if(t[s]!==1)continue;let o=e[s];o>n&&(n=o,r=s)}return r}setSigma(e){if(e===this.sigma)return;let t=~~(Math.sqrt(20*e**2)+1),n=2*t+1,r=new Float32Array(n*n),s=e*e;for(let a=-t;a<=t;a++)for(let o=-t;o<=t;o++){let c=(t+o)*n+a+t,u=a*a+o*o;r[c]=Math.E**(-u/(2*s))}this.lookupTable=r,this.sigma=e,this.radius=t}resize(e){this.size!==e&&(this.size=e,this.score=new Float32Array(e*e),this.binaryPattern=new Uint8Array(e*e))}invert(){let{binaryPattern:e,score:t,size:n}=this;t.fill(0);for(let r=0,s=e.length;r<s;r++)if(e[r]===0){let a=~~(r/n),o=r-a*n;this.updateScore(o,a,1),e[r]=1}else e[r]=0}updateScore(e,t,n){let{size:r,score:s,lookupTable:a}=this,o=this.radius,c=2*o+1;for(let u=-o;u<=o;u++)for(let f=-o;f<=o;f++){let h=(o+f)*c+u+o,l=a[h],p=e+u;p=p<0?r+p:p%r;let g=t+f;g=g<0?r+g:g%r;let b=g*r+p;s[b]+=n*l}}addPointIndex(e){this.binaryPattern[e]=1;let t=this.size,n=~~(e/t),r=e-n*t;this.updateScore(r,n,1),this.count++}removePointIndex(e){this.binaryPattern[e]=0;let t=this.size,n=~~(e/t),r=e-n*t;this.updateScore(r,n,-1),this.count--}copy(e){this.resize(e.size),this.score.set(e.score),this.binaryPattern.set(e.binaryPattern),this.setSigma(e.sigma),this.count=e.count}};var gl=class{constructor(){this.random=Math.random,this.sigma=1.5,this.size=64,this.majorityPointsRatio=.1,this.samples=new wa(1),this.savedSamples=new wa(1)}generate(){let{samples:e,savedSamples:t,sigma:n,majorityPointsRatio:r,size:s}=this;e.resize(s),e.setSigma(n);let a=Math.floor(s*s*r),o=e.binaryPattern;Op(o,a),Bp(o,this.random);for(let h=0,l=o.length;h<l;h++)o[h]===1&&e.addPointIndex(h);for(;;){let h=e.findCluster();e.removePointIndex(h);let l=e.findVoid();if(h===l){e.addPointIndex(h);break}e.addPointIndex(l)}let c=new Uint32Array(s*s);t.copy(e);let u;for(u=e.count-1;u>=0;){let h=e.findCluster();e.removePointIndex(h),c[h]=u,u--}let f=s*s;for(u=t.count;u<f/2;){let h=t.findVoid();t.addPointIndex(h),c[h]=u,u++}for(t.invert();u<f;){let h=t.findCluster();t.removePointIndex(h),c[h]=u,u++}return{data:c,maxValue:f}}};function ky(i){return i>=3?4:i}function Vy(i){switch(i){case 1:return vn;case 2:return Tn;default:return He}}var xl=class extends St{constructor(e=64,t=1){super(new Float32Array(4),1,1,He,qe),this.minFilter=je,this.magFilter=je,this.size=e,this.channels=t,this.update()}update(){let e=this.channels,t=this.size,n=new gl;n.channels=e,n.size=t;let r=ky(e),s=Vy(r);(this.image.width!==t||s!==this.format)&&(this.image.width=t,this.image.height=t,this.image.data=new Float32Array(t**2*r),this.format=s,this.dispose());let a=this.image.data;for(let o=0,c=e;o<c;o++){let u=n.generate(),f=u.data,h=u.maxValue;for(let l=0,p=f.length;l<p;l++){let g=f[l]/h;a[l*r+o]=g}}this.needsUpdate=!0}};var zp=`

	struct PhysicalCamera {

		float focusDistance;
		float anamorphicRatio;
		float bokehSize;
		int apertureBlades;
		float apertureRotation;

	};

`;var kp=`

	struct EquirectHdrInfo {

		sampler2D marginalWeights;
		sampler2D conditionalWeights;
		sampler2D map;

		float totalSum;

	};

`;var Vp=`

	#define RECT_AREA_LIGHT_TYPE 0
	#define CIRC_AREA_LIGHT_TYPE 1
	#define SPOT_LIGHT_TYPE 2
	#define DIR_LIGHT_TYPE 3
	#define POINT_LIGHT_TYPE 4

	struct LightsInfo {

		sampler2D tex;
		uint count;

	};

	struct Light {

		vec3 position;
		int type;

		vec3 color;
		float intensity;

		vec3 u;
		vec3 v;
		float area;

		// spot light fields
		float radius;
		float near;
		float decay;
		float distance;
		float coneCos;
		float penumbraCos;
		int iesProfile;

	};

	Light readLightInfo( sampler2D tex, uint index ) {

		uint i = index * 6u;

		vec4 s0 = texelFetch1D( tex, i + 0u );
		vec4 s1 = texelFetch1D( tex, i + 1u );
		vec4 s2 = texelFetch1D( tex, i + 2u );
		vec4 s3 = texelFetch1D( tex, i + 3u );

		Light l;
		l.position = s0.rgb;
		l.type = int( round( s0.a ) );

		l.color = s1.rgb;
		l.intensity = s1.a;

		l.u = s2.rgb;
		l.v = s3.rgb;
		l.area = s3.a;

		if ( l.type == SPOT_LIGHT_TYPE || l.type == POINT_LIGHT_TYPE ) {

			vec4 s4 = texelFetch1D( tex, i + 4u );
			vec4 s5 = texelFetch1D( tex, i + 5u );
			l.radius = s4.r;
			l.decay = s4.g;
			l.distance = s4.b;
			l.coneCos = s4.a;

			l.penumbraCos = s5.r;
			l.iesProfile = int( round( s5.g ) );

		} else {

			l.radius = 0.0;
			l.decay = 0.0;
			l.distance = 0.0;

			l.coneCos = 0.0;
			l.penumbraCos = 0.0;
			l.iesProfile = - 1;

		}

		return l;

	}

`;var Hp=`

	struct Material {

		vec3 color;
		int map;

		float metalness;
		int metalnessMap;

		float roughness;
		int roughnessMap;

		float ior;
		float transmission;
		int transmissionMap;

		float emissiveIntensity;
		vec3 emissive;
		int emissiveMap;

		int normalMap;
		vec2 normalScale;

		float clearcoat;
		int clearcoatMap;
		int clearcoatNormalMap;
		vec2 clearcoatNormalScale;
		float clearcoatRoughness;
		int clearcoatRoughnessMap;

		int iridescenceMap;
		int iridescenceThicknessMap;
		float iridescence;
		float iridescenceIor;
		float iridescenceThicknessMinimum;
		float iridescenceThicknessMaximum;

		vec3 specularColor;
		int specularColorMap;

		float specularIntensity;
		int specularIntensityMap;
		bool thinFilm;

		vec3 attenuationColor;
		float attenuationDistance;

		int alphaMap;

		bool castShadow;
		float opacity;
		float alphaTest;

		float side;
		bool matte;

		float sheen;
		vec3 sheenColor;
		int sheenColorMap;
		float sheenRoughness;
		int sheenRoughnessMap;

		bool vertexColors;
		bool flatShading;
		bool transparent;
		bool fogVolume;

		mat3 mapTransform;
		mat3 metalnessMapTransform;
		mat3 roughnessMapTransform;
		mat3 transmissionMapTransform;
		mat3 emissiveMapTransform;
		mat3 normalMapTransform;
		mat3 clearcoatMapTransform;
		mat3 clearcoatNormalMapTransform;
		mat3 clearcoatRoughnessMapTransform;
		mat3 sheenColorMapTransform;
		mat3 sheenRoughnessMapTransform;
		mat3 iridescenceMapTransform;
		mat3 iridescenceThicknessMapTransform;
		mat3 specularColorMapTransform;
		mat3 specularIntensityMapTransform;
		mat3 alphaMapTransform;

	};

	mat3 readTextureTransform( sampler2D tex, uint index ) {

		mat3 textureTransform;

		vec4 row1 = texelFetch1D( tex, index );
		vec4 row2 = texelFetch1D( tex, index + 1u );

		textureTransform[0] = vec3(row1.r, row2.r, 0.0);
		textureTransform[1] = vec3(row1.g, row2.g, 0.0);
		textureTransform[2] = vec3(row1.b, row2.b, 1.0);

		return textureTransform;

	}

	Material readMaterialInfo( sampler2D tex, uint index ) {

		uint i = index * uint( MATERIAL_PIXELS );

		vec4 s0 = texelFetch1D( tex, i + 0u );
		vec4 s1 = texelFetch1D( tex, i + 1u );
		vec4 s2 = texelFetch1D( tex, i + 2u );
		vec4 s3 = texelFetch1D( tex, i + 3u );
		vec4 s4 = texelFetch1D( tex, i + 4u );
		vec4 s5 = texelFetch1D( tex, i + 5u );
		vec4 s6 = texelFetch1D( tex, i + 6u );
		vec4 s7 = texelFetch1D( tex, i + 7u );
		vec4 s8 = texelFetch1D( tex, i + 8u );
		vec4 s9 = texelFetch1D( tex, i + 9u );
		vec4 s10 = texelFetch1D( tex, i + 10u );
		vec4 s11 = texelFetch1D( tex, i + 11u );
		vec4 s12 = texelFetch1D( tex, i + 12u );
		vec4 s13 = texelFetch1D( tex, i + 13u );
		vec4 s14 = texelFetch1D( tex, i + 14u );

		Material m;
		m.color = s0.rgb;
		m.map = int( round( s0.a ) );

		m.metalness = s1.r;
		m.metalnessMap = int( round( s1.g ) );
		m.roughness = s1.b;
		m.roughnessMap = int( round( s1.a ) );

		m.ior = s2.r;
		m.transmission = s2.g;
		m.transmissionMap = int( round( s2.b ) );
		m.emissiveIntensity = s2.a;

		m.emissive = s3.rgb;
		m.emissiveMap = int( round( s3.a ) );

		m.normalMap = int( round( s4.r ) );
		m.normalScale = s4.gb;

		m.clearcoat = s4.a;
		m.clearcoatMap = int( round( s5.r ) );
		m.clearcoatRoughness = s5.g;
		m.clearcoatRoughnessMap = int( round( s5.b ) );
		m.clearcoatNormalMap = int( round( s5.a ) );
		m.clearcoatNormalScale = s6.rg;

		m.sheen = s6.a;
		m.sheenColor = s7.rgb;
		m.sheenColorMap = int( round( s7.a ) );
		m.sheenRoughness = s8.r;
		m.sheenRoughnessMap = int( round( s8.g ) );

		m.iridescenceMap = int( round( s8.b ) );
		m.iridescenceThicknessMap = int( round( s8.a ) );
		m.iridescence = s9.r;
		m.iridescenceIor = s9.g;
		m.iridescenceThicknessMinimum = s9.b;
		m.iridescenceThicknessMaximum = s9.a;

		m.specularColor = s10.rgb;
		m.specularColorMap = int( round( s10.a ) );

		m.specularIntensity = s11.r;
		m.specularIntensityMap = int( round( s11.g ) );
		m.thinFilm = bool( s11.b );

		m.attenuationColor = s12.rgb;
		m.attenuationDistance = s12.a;

		m.alphaMap = int( round( s13.r ) );

		m.opacity = s13.g;
		m.alphaTest = s13.b;
		m.side = s13.a;

		m.matte = bool( s14.r );
		m.castShadow = bool( s14.g );
		m.vertexColors = bool( int( s14.b ) & 1 );
		m.flatShading = bool( int( s14.b ) & 2 );
		m.fogVolume = bool( int( s14.b ) & 4 );
		m.transparent = bool( s14.a );

		uint firstTextureTransformIdx = i + 15u;

		// mat3( 1.0 ) is an identity matrix
		m.mapTransform = m.map == - 1 ? mat3( 1.0 ) : readTextureTransform( tex, firstTextureTransformIdx );
		m.metalnessMapTransform = m.metalnessMap == - 1 ? mat3( 1.0 ) : readTextureTransform( tex, firstTextureTransformIdx + 2u );
		m.roughnessMapTransform = m.roughnessMap == - 1 ? mat3( 1.0 ) : readTextureTransform( tex, firstTextureTransformIdx + 4u );
		m.transmissionMapTransform = m.transmissionMap == - 1 ? mat3( 1.0 ) : readTextureTransform( tex, firstTextureTransformIdx + 6u );
		m.emissiveMapTransform = m.emissiveMap == - 1 ? mat3( 1.0 ) : readTextureTransform( tex, firstTextureTransformIdx + 8u );
		m.normalMapTransform = m.normalMap == - 1 ? mat3( 1.0 ) : readTextureTransform( tex, firstTextureTransformIdx + 10u );
		m.clearcoatMapTransform = m.clearcoatMap == - 1 ? mat3( 1.0 ) : readTextureTransform( tex, firstTextureTransformIdx + 12u );
		m.clearcoatNormalMapTransform = m.clearcoatNormalMap == - 1 ? mat3( 1.0 ) : readTextureTransform( tex, firstTextureTransformIdx + 14u );
		m.clearcoatRoughnessMapTransform = m.clearcoatRoughnessMap == - 1 ? mat3( 1.0 ) : readTextureTransform( tex, firstTextureTransformIdx + 16u );
		m.sheenColorMapTransform = m.sheenColorMap == - 1 ? mat3( 1.0 ) : readTextureTransform( tex, firstTextureTransformIdx + 18u );
		m.sheenRoughnessMapTransform = m.sheenRoughnessMap == - 1 ? mat3( 1.0 ) : readTextureTransform( tex, firstTextureTransformIdx + 20u );
		m.iridescenceMapTransform = m.iridescenceMap == - 1 ? mat3( 1.0 ) : readTextureTransform( tex, firstTextureTransformIdx + 22u );
		m.iridescenceThicknessMapTransform = m.iridescenceThicknessMap == - 1 ? mat3( 1.0 ) : readTextureTransform( tex, firstTextureTransformIdx + 24u );
		m.specularColorMapTransform = m.specularColorMap == - 1 ? mat3( 1.0 ) : readTextureTransform( tex, firstTextureTransformIdx + 26u );
		m.specularIntensityMapTransform = m.specularIntensityMap == - 1 ? mat3( 1.0 ) : readTextureTransform( tex, firstTextureTransformIdx + 28u );
		m.alphaMapTransform = m.alphaMap == - 1 ? mat3( 1.0 ) : readTextureTransform( tex, firstTextureTransformIdx + 30u );

		return m;

	}

`;var Gp=`

	struct SurfaceRecord {

		// surface type
		bool volumeParticle;

		// geometry
		vec3 faceNormal;
		bool frontFace;
		vec3 normal;
		mat3 normalBasis;
		mat3 normalInvBasis;

		// cached properties
		float eta;
		float f0;

		// material
		float roughness;
		float filteredRoughness;
		float metalness;
		vec3 color;
		vec3 emission;

		// transmission
		float ior;
		float transmission;
		bool thinFilm;
		vec3 attenuationColor;
		float attenuationDistance;

		// clearcoat
		vec3 clearcoatNormal;
		mat3 clearcoatBasis;
		mat3 clearcoatInvBasis;
		float clearcoat;
		float clearcoatRoughness;
		float filteredClearcoatRoughness;

		// sheen
		float sheen;
		vec3 sheenColor;
		float sheenRoughness;

		// iridescence
		float iridescence;
		float iridescenceIor;
		float iridescenceThickness;

		// specular
		vec3 specularColor;
		float specularIntensity;
	};

	struct ScatterRecord {
		float specularPdf;
		float pdf;
		vec3 direction;
		vec3 color;
	};

`;var Wp=`

	// samples the the given environment map in the given direction
	vec3 sampleEquirectColor( sampler2D envMap, vec3 direction ) {

		return texture2D( envMap, equirectDirectionToUv( direction ) ).rgb;

	}

	// gets the pdf of the given direction to sample
	float equirectDirectionPdf( vec3 direction ) {

		vec2 uv = equirectDirectionToUv( direction );
		float theta = uv.y * PI;
		float sinTheta = sin( theta );
		if ( sinTheta == 0.0 ) {

			return 0.0;

		}

		return 1.0 / ( 2.0 * PI * PI * sinTheta );

	}

	// samples the color given env map with CDF and returns the pdf of the direction
	float sampleEquirect( vec3 direction, inout vec3 color ) {

		float totalSum = envMapInfo.totalSum;
		if ( totalSum == 0.0 ) {

			color = vec3( 0.0 );
			return 1.0;

		}

		vec2 uv = equirectDirectionToUv( direction );
		color = texture2D( envMapInfo.map, uv ).rgb;

		float lum = luminance( color );
		ivec2 resolution = textureSize( envMapInfo.map, 0 );
		float pdf = lum / totalSum;

		return float( resolution.x * resolution.y ) * pdf * equirectDirectionPdf( direction );

	}

	// samples a direction of the envmap with color and retrieves pdf
	float sampleEquirectProbability( vec2 r, inout vec3 color, inout vec3 direction ) {

		// sample env map cdf
		float v = texture2D( envMapInfo.marginalWeights, vec2( r.x, 0.0 ) ).x;
		float u = texture2D( envMapInfo.conditionalWeights, vec2( r.y, v ) ).x;
		vec2 uv = vec2( u, v );

		vec3 derivedDirection = equirectUvToDirection( uv );
		direction = derivedDirection;
		color = texture2D( envMapInfo.map, uv ).rgb;

		float totalSum = envMapInfo.totalSum;
		float lum = luminance( color );
		ivec2 resolution = textureSize( envMapInfo.map, 0 );
		float pdf = lum / totalSum;

		return float( resolution.x * resolution.y ) * pdf * equirectDirectionPdf( direction );

	}
`;var Xp=`

	float getSpotAttenuation( const in float coneCosine, const in float penumbraCosine, const in float angleCosine ) {

		return smoothstep( coneCosine, penumbraCosine, angleCosine );

	}

	float getDistanceAttenuation( const in float lightDistance, const in float cutoffDistance, const in float decayExponent ) {

		// based upon Frostbite 3 Moving to Physically-based Rendering
		// page 32, equation 26: E[window1]
		// https://seblagarde.files.wordpress.com/2015/07/course_notes_moving_frostbite_to_pbr_v32.pdf
		float distanceFalloff = 1.0 / max( pow( lightDistance, decayExponent ), EPSILON );

		if ( cutoffDistance > 0.0 ) {

			distanceFalloff *= pow2( saturate( 1.0 - pow4( lightDistance / cutoffDistance ) ) );

		}

		return distanceFalloff;

	}

	float getPhotometricAttenuation( sampler2DArray iesProfiles, int iesProfile, vec3 posToLight, vec3 lightDir, vec3 u, vec3 v ) {

		float cosTheta = dot( posToLight, lightDir );
		float angle = acos( cosTheta ) / PI;

		return texture2D( iesProfiles, vec3( angle, 0.0, iesProfile ) ).r;

	}

	struct LightRecord {

		float dist;
		vec3 direction;
		float pdf;
		vec3 emission;
		int type;

	};

	bool intersectLightAtIndex( sampler2D lights, vec3 rayOrigin, vec3 rayDirection, uint l, inout LightRecord lightRec ) {

		bool didHit = false;
		Light light = readLightInfo( lights, l );

		vec3 u = light.u;
		vec3 v = light.v;

		// check for backface
		vec3 normal = normalize( cross( u, v ) );
		if ( dot( normal, rayDirection ) > 0.0 ) {

			u *= 1.0 / dot( u, u );
			v *= 1.0 / dot( v, v );

			float dist;

			// MIS / light intersection is not supported for punctual lights.
			if(
				( light.type == RECT_AREA_LIGHT_TYPE && intersectsRectangle( light.position, normal, u, v, rayOrigin, rayDirection, dist ) ) ||
				( light.type == CIRC_AREA_LIGHT_TYPE && intersectsCircle( light.position, normal, u, v, rayOrigin, rayDirection, dist ) )
			) {

				float cosTheta = dot( rayDirection, normal );
				didHit = true;
				lightRec.dist = dist;
				lightRec.pdf = ( dist * dist ) / ( light.area * cosTheta );
				lightRec.emission = light.color * light.intensity;
				lightRec.direction = rayDirection;
				lightRec.type = light.type;

			}

		}

		return didHit;

	}

	LightRecord randomAreaLightSample( Light light, vec3 rayOrigin, vec2 ruv ) {

		vec3 randomPos;
		if( light.type == RECT_AREA_LIGHT_TYPE ) {

			// rectangular area light
			randomPos = light.position + light.u * ( ruv.x - 0.5 ) + light.v * ( ruv.y - 0.5 );

		} else if( light.type == CIRC_AREA_LIGHT_TYPE ) {

			// circular area light
			float r = 0.5 * sqrt( ruv.x );
			float theta = ruv.y * 2.0 * PI;
			float x = r * cos( theta );
			float y = r * sin( theta );

			randomPos = light.position + light.u * x + light.v * y;

		}

		vec3 toLight = randomPos - rayOrigin;
		float lightDistSq = dot( toLight, toLight );
		float dist = sqrt( lightDistSq );
		vec3 direction = toLight / dist;
		vec3 lightNormal = normalize( cross( light.u, light.v ) );

		LightRecord lightRec;
		lightRec.type = light.type;
		lightRec.emission = light.color * light.intensity;
		lightRec.dist = dist;
		lightRec.direction = direction;

		// TODO: the denominator is potentially zero
		lightRec.pdf = lightDistSq / ( light.area * dot( direction, lightNormal ) );

		return lightRec;

	}

	LightRecord randomSpotLightSample( Light light, sampler2DArray iesProfiles, vec3 rayOrigin, vec2 ruv ) {

		float radius = light.radius * sqrt( ruv.x );
		float theta = ruv.y * 2.0 * PI;
		float x = radius * cos( theta );
		float y = radius * sin( theta );

		vec3 u = light.u;
		vec3 v = light.v;
		vec3 normal = normalize( cross( u, v ) );

		float angle = acos( light.coneCos );
		float angleTan = tan( angle );
		float startDistance = light.radius / max( angleTan, EPSILON );

		vec3 randomPos = light.position - normal * startDistance + u * x + v * y;
		vec3 toLight = randomPos - rayOrigin;
		float lightDistSq = dot( toLight, toLight );
		float dist = sqrt( lightDistSq );

		vec3 direction = toLight / max( dist, EPSILON );
		float cosTheta = dot( direction, normal );

		float spotAttenuation = light.iesProfile != - 1 ?
			getPhotometricAttenuation( iesProfiles, light.iesProfile, direction, normal, u, v ) :
			getSpotAttenuation( light.coneCos, light.penumbraCos, cosTheta );

		float distanceAttenuation = getDistanceAttenuation( dist, light.distance, light.decay );
		LightRecord lightRec;
		lightRec.type = light.type;
		lightRec.dist = dist;
		lightRec.direction = direction;
		lightRec.emission = light.color * light.intensity * distanceAttenuation * spotAttenuation;
		lightRec.pdf = 1.0;

		return lightRec;

	}

	LightRecord randomLightSample( sampler2D lights, sampler2DArray iesProfiles, uint lightCount, vec3 rayOrigin, vec3 ruv ) {

		LightRecord result;

		// pick a random light
		uint l = uint( ruv.x * float( lightCount ) );
		Light light = readLightInfo( lights, l );

		if ( light.type == SPOT_LIGHT_TYPE ) {

			result = randomSpotLightSample( light, iesProfiles, rayOrigin, ruv.yz );

		} else if ( light.type == POINT_LIGHT_TYPE ) {

			vec3 lightRay = light.u - rayOrigin;
			float lightDist = length( lightRay );
			float cutoffDistance = light.distance;
			float distanceFalloff = 1.0 / max( pow( lightDist, light.decay ), 0.01 );
			if ( cutoffDistance > 0.0 ) {

				distanceFalloff *= pow2( saturate( 1.0 - pow4( lightDist / cutoffDistance ) ) );

			}

			LightRecord rec;
			rec.direction = normalize( lightRay );
			rec.dist = length( lightRay );
			rec.pdf = 1.0;
			rec.emission = light.color * light.intensity * distanceFalloff;
			rec.type = light.type;
			result = rec;

		} else if ( light.type == DIR_LIGHT_TYPE ) {

			LightRecord rec;
			rec.dist = 1e10;
			rec.direction = light.u;
			rec.pdf = 1.0;
			rec.emission = light.color * light.intensity;
			rec.type = light.type;

			result = rec;

		} else {

			// sample the light
			result = randomAreaLightSample( light, rayOrigin, ruv.yz );

		}

		return result;

	}

`;var qp=`

	vec3 sampleHemisphere( vec3 n, vec2 uv ) {

		// https://www.rorydriscoll.com/2009/01/07/better-sampling/
		// https://graphics.pixar.com/library/OrthonormalB/paper.pdf
		float sign = n.z == 0.0 ? 1.0 : sign( n.z );
		float a = - 1.0 / ( sign + n.z );
		float b = n.x * n.y * a;
		vec3 b1 = vec3( 1.0 + sign * n.x * n.x * a, sign * b, - sign * n.x );
		vec3 b2 = vec3( b, sign + n.y * n.y * a, - n.y );

		float r = sqrt( uv.x );
		float theta = 2.0 * PI * uv.y;
		float x = r * cos( theta );
		float y = r * sin( theta );
		return x * b1 + y * b2 + sqrt( 1.0 - uv.x ) * n;

	}

	vec2 sampleTriangle( vec2 a, vec2 b, vec2 c, vec2 r ) {

		// get the edges of the triangle and the diagonal across the
		// center of the parallelogram
		vec2 e1 = a - b;
		vec2 e2 = c - b;
		vec2 diag = normalize( e1 + e2 );

		// pick the point in the parallelogram
		if ( r.x + r.y > 1.0 ) {

			r = vec2( 1.0 ) - r;

		}

		return e1 * r.x + e2 * r.y;

	}

	vec2 sampleCircle( vec2 uv ) {

		float angle = 2.0 * PI * uv.x;
		float radius = sqrt( uv.y );
		return vec2( cos( angle ), sin( angle ) ) * radius;

	}

	vec3 sampleSphere( vec2 uv ) {

		float u = ( uv.x - 0.5 ) * 2.0;
		float t = uv.y * PI * 2.0;
		float f = sqrt( 1.0 - u * u );

		return vec3( f * cos( t ), f * sin( t ), u );

	}

	vec2 sampleRegularPolygon( int sides, vec3 uvw ) {

		sides = max( sides, 3 );

		vec3 r = uvw;
		float anglePerSegment = 2.0 * PI / float( sides );
		float segment = floor( float( sides ) * r.x );

		float angle1 = anglePerSegment * segment;
		float angle2 = angle1 + anglePerSegment;
		vec2 a = vec2( sin( angle1 ), cos( angle1 ) );
		vec2 b = vec2( 0.0, 0.0 );
		vec2 c = vec2( sin( angle2 ), cos( angle2 ) );

		return sampleTriangle( a, b, c, r.yz );

	}

	// samples an aperture shape with the given number of sides. 0 means circle
	vec2 sampleAperture( int blades, vec3 uvw ) {

		return blades == 0 ?
			sampleCircle( uvw.xy ) :
			sampleRegularPolygon( blades, uvw );

	}


`;var Yp=`

	bool totalInternalReflection( float cosTheta, float eta ) {

		float sinTheta = sqrt( 1.0 - cosTheta * cosTheta );
		return eta * sinTheta > 1.0;

	}

	// https://google.github.io/filament/Filament.md.html#materialsystem/diffusebrdf
	float schlickFresnel( float cosine, float f0 ) {

		return f0 + ( 1.0 - f0 ) * pow( 1.0 - cosine, 5.0 );

	}

	vec3 schlickFresnel( float cosine, vec3 f0 ) {

		return f0 + ( 1.0 - f0 ) * pow( 1.0 - cosine, 5.0 );

	}

	vec3 schlickFresnel( float cosine, vec3 f0, vec3 f90 ) {

		return f0 + ( f90 - f0 ) * pow( 1.0 - cosine, 5.0 );

	}

	float dielectricFresnel( float cosThetaI, float eta ) {

		// https://schuttejoe.github.io/post/disneybsdf/
		float ni = eta;
		float nt = 1.0;

		// Check for total internal reflection
		float sinThetaISq = 1.0f - cosThetaI * cosThetaI;
		float sinThetaTSq = eta * eta * sinThetaISq;
		if( sinThetaTSq >= 1.0 ) {

			return 1.0;

		}

		float sinThetaT = sqrt( sinThetaTSq );

		float cosThetaT = sqrt( max( 0.0, 1.0f - sinThetaT * sinThetaT ) );
		float rParallel = ( ( nt * cosThetaI ) - ( ni * cosThetaT ) ) / ( ( nt * cosThetaI ) + ( ni * cosThetaT ) );
		float rPerpendicular = ( ( ni * cosThetaI ) - ( nt * cosThetaT ) ) / ( ( ni * cosThetaI ) + ( nt * cosThetaT ) );
		return ( rParallel * rParallel + rPerpendicular * rPerpendicular ) / 2.0;

	}

	// https://raytracing.github.io/books/RayTracingInOneWeekend.html#dielectrics/schlickapproximation
	float iorRatioToF0( float eta ) {

		return pow( ( 1.0 - eta ) / ( 1.0 + eta ), 2.0 );

	}

	vec3 evaluateFresnel( float cosTheta, float eta, vec3 f0, vec3 f90 ) {

		if ( totalInternalReflection( cosTheta, eta ) ) {

			return f90;

		}

		return schlickFresnel( cosTheta, f0, f90 );

	}

	// TODO: disney fresnel was removed and replaced with this fresnel function to better align with
	// the glTF but is causing blown out pixels. Should be revisited
	// float evaluateFresnelWeight( float cosTheta, float eta, float f0 ) {

	// 	if ( totalInternalReflection( cosTheta, eta ) ) {

	// 		return 1.0;

	// 	}

	// 	return schlickFresnel( cosTheta, f0 );

	// }

	// https://schuttejoe.github.io/post/disneybsdf/
	float disneyFresnel( vec3 wo, vec3 wi, vec3 wh, float f0, float eta, float metalness ) {

		float dotHV = dot( wo, wh );
		if ( totalInternalReflection( dotHV, eta ) ) {

			return 1.0;

		}

		float dotHL = dot( wi, wh );
		float dielectricFresnel = dielectricFresnel( abs( dotHV ), eta );
		float metallicFresnel = schlickFresnel( dotHL, f0 );

		return mix( dielectricFresnel, metallicFresnel, metalness );

	}

`;var Zp=`

	// Fast arccos approximation used to remove banding artifacts caused by numerical errors in acos.
	// This is a cubic Lagrange interpolating polynomial for x = [-1, -1/2, 0, 1/2, 1].
	// For more information see: https://github.com/gkjohnson/three-gpu-pathtracer/pull/171#issuecomment-1152275248
	float acosApprox( float x ) {

		x = clamp( x, -1.0, 1.0 );
		return ( - 0.69813170079773212 * x * x - 0.87266462599716477 ) * x + 1.5707963267948966;

	}

	// An acos with input values bound to the range [-1, 1].
	float acosSafe( float x ) {

		return acos( clamp( x, -1.0, 1.0 ) );

	}

	float saturateCos( float val ) {

		return clamp( val, 0.001, 1.0 );

	}

	float square( float t ) {

		return t * t;

	}

	vec2 square( vec2 t ) {

		return t * t;

	}

	vec3 square( vec3 t ) {

		return t * t;

	}

	vec4 square( vec4 t ) {

		return t * t;

	}

	vec2 rotateVector( vec2 v, float t ) {

		float ac = cos( t );
		float as = sin( t );
		return vec2(
			v.x * ac - v.y * as,
			v.x * as + v.y * ac
		);

	}

	// forms a basis with the normal vector as Z
	mat3 getBasisFromNormal( vec3 normal ) {

		vec3 other;
		if ( abs( normal.x ) > 0.5 ) {

			other = vec3( 0.0, 1.0, 0.0 );

		} else {

			other = vec3( 1.0, 0.0, 0.0 );

		}

		vec3 ortho = normalize( cross( normal, other ) );
		vec3 ortho2 = normalize( cross( normal, ortho ) );
		return mat3( ortho2, ortho, normal );

	}

`;var $p=`

	// Finds the point where the ray intersects the plane defined by u and v and checks if this point
	// falls in the bounds of the rectangle on that same plane.
	// Plane intersection: https://lousodrome.net/blog/light/2020/07/03/intersection-of-a-ray-and-a-plane/
	bool intersectsRectangle( vec3 center, vec3 normal, vec3 u, vec3 v, vec3 rayOrigin, vec3 rayDirection, inout float dist ) {

		float t = dot( center - rayOrigin, normal ) / dot( rayDirection, normal );

		if ( t > EPSILON ) {

			vec3 p = rayOrigin + rayDirection * t;
			vec3 vi = p - center;

			// check if p falls inside the rectangle
			float a1 = dot( u, vi );
			if ( abs( a1 ) <= 0.5 ) {

				float a2 = dot( v, vi );
				if ( abs( a2 ) <= 0.5 ) {

					dist = t;
					return true;

				}

			}

		}

		return false;

	}

	// Finds the point where the ray intersects the plane defined by u and v and checks if this point
	// falls in the bounds of the circle on that same plane. See above URL for a description of the plane intersection algorithm.
	bool intersectsCircle( vec3 position, vec3 normal, vec3 u, vec3 v, vec3 rayOrigin, vec3 rayDirection, inout float dist ) {

		float t = dot( position - rayOrigin, normal ) / dot( rayDirection, normal );

		if ( t > EPSILON ) {

			vec3 hit = rayOrigin + rayDirection * t;
			vec3 vi = hit - position;

			float a1 = dot( u, vi );
			float a2 = dot( v, vi );

			if( length( vec2( a1, a2 ) ) <= 0.5 ) {

				dist = t;
				return true;

			}

		}

		return false;

	}

`;var Jp=`

	// add texel fetch functions for texture arrays
	vec4 texelFetch1D( sampler2DArray tex, int layer, uint index ) {

		uint width = uint( textureSize( tex, 0 ).x );
		uvec2 uv;
		uv.x = index % width;
		uv.y = index / width;

		return texelFetch( tex, ivec3( uv, layer ), 0 );

	}

	vec4 textureSampleBarycoord( sampler2DArray tex, int layer, vec3 barycoord, uvec3 faceIndices ) {

		return
			barycoord.x * texelFetch1D( tex, layer, faceIndices.x ) +
			barycoord.y * texelFetch1D( tex, layer, faceIndices.y ) +
			barycoord.z * texelFetch1D( tex, layer, faceIndices.z );

	}

`;var vl=`

	// TODO: possibly this should be renamed something related to material or path tracing logic

	#ifndef RAY_OFFSET
	#define RAY_OFFSET 1e-4
	#endif

	// adjust the hit point by the surface normal by a factor of some offset and the
	// maximum component-wise value of the current point to accommodate floating point
	// error as values increase.
	vec3 stepRayOrigin( vec3 rayOrigin, vec3 rayDirection, vec3 offset, float dist ) {

		vec3 point = rayOrigin + rayDirection * dist;
		vec3 absPoint = abs( point );
		float maxPoint = max( absPoint.x, max( absPoint.y, absPoint.z ) );
		return point + offset * ( maxPoint + 1.0 ) * RAY_OFFSET;

	}

	// https://github.com/KhronosGroup/glTF/blob/main/extensions/2.0/Khronos/KHR_materials_volume/README.md#attenuation
	vec3 transmissionAttenuation( float dist, vec3 attColor, float attDist ) {

		vec3 ot = - log( attColor ) / attDist;
		return exp( - ot * dist );

	}

	vec3 getHalfVector( vec3 wi, vec3 wo, float eta ) {

		// get the half vector - assuming if the light incident vector is on the other side
		// of the that it's transmissive.
		vec3 h;
		if ( wi.z > 0.0 ) {

			h = normalize( wi + wo );

		} else {

			// Scale by the ior ratio to retrieve the appropriate half vector
			// From Section 2.2 on computing the transmission half vector:
			// https://blog.selfshadow.com/publications/s2015-shading-course/burley/s2015_pbs_disney_bsdf_notes.pdf
			h = normalize( wi + wo * eta );

		}

		h *= sign( h.z );
		return h;

	}

	vec3 getHalfVector( vec3 a, vec3 b ) {

		return normalize( a + b );

	}

	// The discrepancy between interpolated surface normal and geometry normal can cause issues when a ray
	// is cast that is on the top side of the geometry normal plane but below the surface normal plane. If
	// we find a ray like that we ignore it to avoid artifacts.
	// This function returns if the direction is on the same side of both planes.
	bool isDirectionValid( vec3 direction, vec3 surfaceNormal, vec3 geometryNormal ) {

		bool aboveSurfaceNormal = dot( direction, surfaceNormal ) > 0.0;
		bool aboveGeometryNormal = dot( direction, geometryNormal ) > 0.0;
		return aboveSurfaceNormal == aboveGeometryNormal;

	}

	// ray sampling x and z are swapped to align with expected background view
	vec2 equirectDirectionToUv( vec3 direction ) {

		// from Spherical.setFromCartesianCoords
		vec2 uv = vec2( atan( direction.z, direction.x ), acos( direction.y ) );
		uv /= vec2( 2.0 * PI, PI );

		// apply adjustments to get values in range [0, 1] and y right side up
		uv.x += 0.5;
		uv.y = 1.0 - uv.y;
		return uv;

	}

	vec3 equirectUvToDirection( vec2 uv ) {

		// undo above adjustments
		uv.x -= 0.5;
		uv.y = 1.0 - uv.y;

		// from Vector3.setFromSphericalCoords
		float theta = uv.x * 2.0 * PI;
		float phi = uv.y * PI;

		float sinPhi = sin( phi );

		return vec3( sinPhi * cos( theta ), cos( phi ), sinPhi * sin( theta ) );

	}

	// power heuristic for multiple importance sampling
	float misHeuristic( float a, float b ) {

		float aa = a * a;
		float bb = b * b;
		return aa / ( aa + bb );

	}

	// tentFilter from Peter Shirley's 'Realistic Ray Tracing (2nd Edition)' book, pg. 60
	// erichlof/THREE.js-PathTracing-Renderer/
	float tentFilter( float x ) {

		return x < 0.5 ? sqrt( 2.0 * x ) - 1.0 : 1.0 - sqrt( 2.0 - ( 2.0 * x ) );

	}
`;var Ih=`

	// https://www.shadertoy.com/view/wltcRS
	uvec4 WHITE_NOISE_SEED;

	void rng_initialize( vec2 p, int frame ) {

		// white noise seed
		WHITE_NOISE_SEED = uvec4( p, uint( frame ), uint( p.x ) + uint( p.y ) );

	}

	// https://www.pcg-random.org/
	void pcg4d( inout uvec4 v ) {

		v = v * 1664525u + 1013904223u;
		v.x += v.y * v.w;
		v.y += v.z * v.x;
		v.z += v.x * v.y;
		v.w += v.y * v.z;
		v = v ^ ( v >> 16u );
		v.x += v.y*v.w;
		v.y += v.z*v.x;
		v.z += v.x*v.y;
		v.w += v.y*v.z;

	}

	// returns [ 0, 1 ]
	float pcgRand() {

		pcg4d( WHITE_NOISE_SEED );
		return float( WHITE_NOISE_SEED.x ) / float( 0xffffffffu );

	}

	vec2 pcgRand2() {

		pcg4d( WHITE_NOISE_SEED );
		return vec2( WHITE_NOISE_SEED.xy ) / float(0xffffffffu);

	}

	vec3 pcgRand3() {

		pcg4d( WHITE_NOISE_SEED );
		return vec3( WHITE_NOISE_SEED.xyz ) / float( 0xffffffffu );

	}

	vec4 pcgRand4() {

		pcg4d( WHITE_NOISE_SEED );
		return vec4( WHITE_NOISE_SEED ) / float( 0xffffffffu );

	}
`;var Kp=`

	uniform sampler2D stratifiedTexture;
	uniform sampler2D stratifiedOffsetTexture;

	uint sobolPixelIndex = 0u;
	uint sobolPathIndex = 0u;
	uint sobolBounceIndex = 0u;
	vec4 pixelSeed = vec4( 0 );

	vec4 rand4( int v ) {

		ivec2 uv = ivec2( v, sobolBounceIndex );
		vec4 stratifiedSample = texelFetch( stratifiedTexture, uv, 0 );
		return fract( stratifiedSample + pixelSeed.r ); // blue noise + stratified samples

	}

	vec3 rand3( int v ) {

		return rand4( v ).xyz;

	}

	vec2 rand2( int v ) {

		return rand4( v ).xy;

	}

	float rand( int v ) {

		return rand4( v ).x;

	}

	void rng_initialize( vec2 screenCoord, int frame ) {

		// tile the small noise texture across the entire screen
		ivec2 noiseSize = ivec2( textureSize( stratifiedOffsetTexture, 0 ) );
		ivec2 pixel = ivec2( screenCoord.xy ) % noiseSize;
		vec2 pixelWidth = 1.0 / vec2( noiseSize );
		vec2 uv = vec2( pixel ) * pixelWidth + pixelWidth * 0.5;

		// note that using "texelFetch" here seems to break Android for some reason
		pixelSeed = texture( stratifiedOffsetTexture, uv );

	}

`;var Qp=`

	// diffuse
	float diffuseEval( vec3 wo, vec3 wi, vec3 wh, SurfaceRecord surf, inout vec3 color ) {

		// https://schuttejoe.github.io/post/disneybsdf/
		float fl = schlickFresnel( wi.z, 0.0 );
		float fv = schlickFresnel( wo.z, 0.0 );

		float metalFactor = ( 1.0 - surf.metalness );
		float transFactor = ( 1.0 - surf.transmission );
		float rr = 0.5 + 2.0 * surf.roughness * fl * fl;
		float retro = rr * ( fl + fv + fl * fv * ( rr - 1.0f ) );
		float lambert = ( 1.0f - 0.5f * fl ) * ( 1.0f - 0.5f * fv );

		// TODO: subsurface approx?

		// float F = evaluateFresnelWeight( dot( wo, wh ), surf.eta, surf.f0 );
		float F = disneyFresnel( wo, wi, wh, surf.f0, surf.eta, surf.metalness );
		color = ( 1.0 - F ) * transFactor * metalFactor * wi.z * surf.color * ( retro + lambert ) / PI;

		return wi.z / PI;

	}

	vec3 diffuseDirection( vec3 wo, SurfaceRecord surf ) {

		vec3 lightDirection = sampleSphere( rand2( 11 ) );
		lightDirection.z += 1.0;
		lightDirection = normalize( lightDirection );

		return lightDirection;

	}

	// specular
	float specularEval( vec3 wo, vec3 wi, vec3 wh, SurfaceRecord surf, inout vec3 color ) {

		// if roughness is set to 0 then D === NaN which results in black pixels
		float metalness = surf.metalness;
		float roughness = surf.filteredRoughness;

		float eta = surf.eta;
		float f0 = surf.f0;

		vec3 f0Color = mix( f0 * surf.specularColor * surf.specularIntensity, surf.color, surf.metalness );
		vec3 f90Color = vec3( mix( surf.specularIntensity, 1.0, surf.metalness ) );
		vec3 F = evaluateFresnel( dot( wo, wh ), eta, f0Color, f90Color );

		vec3 iridescenceF = evalIridescence( 1.0, surf.iridescenceIor, dot( wi, wh ), surf.iridescenceThickness, f0Color );
		F = mix( F, iridescenceF,  surf.iridescence );

		// PDF
		// See 14.1.1 Microfacet BxDFs in https://www.pbr-book.org/
		float incidentTheta = acos( wo.z );
		float G = ggxShadowMaskG2( wi, wo, roughness );
		float D = ggxDistribution( wh, roughness );
		float G1 = ggxShadowMaskG1( incidentTheta, roughness );
		float ggxPdf = D * G1 * max( 0.0, abs( dot( wo, wh ) ) ) / abs ( wo.z );

		color = wi.z * F * G * D / ( 4.0 * abs( wi.z * wo.z ) );
		return ggxPdf / ( 4.0 * dot( wo, wh ) );

	}

	vec3 specularDirection( vec3 wo, SurfaceRecord surf ) {

		// sample ggx vndf distribution which gives a new normal
		float roughness = surf.filteredRoughness;
		vec3 halfVector = ggxDirection(
			wo,
			vec2( roughness ),
			rand2( 12 )
		);

		// apply to new ray by reflecting off the new normal
		return - reflect( wo, halfVector );

	}


	// transmission
	/*
	float transmissionEval( vec3 wo, vec3 wi, vec3 wh, SurfaceRecord surf, inout vec3 color ) {

		// See section 4.2 in https://www.cs.cornell.edu/~srm/publications/EGSR07-btdf.pdf

		float filteredRoughness = surf.filteredRoughness;
		float eta = surf.eta;
		bool frontFace = surf.frontFace;
		bool thinFilm = surf.thinFilm;

		color = surf.transmission * surf.color;

		float denom = pow( eta * dot( wi, wh ) + dot( wo, wh ), 2.0 );
		return ggxPDF( wo, wh, filteredRoughness ) / denom;

	}

	vec3 transmissionDirection( vec3 wo, SurfaceRecord surf ) {

		float filteredRoughness = surf.filteredRoughness;
		float eta = surf.eta;
		bool frontFace = surf.frontFace;

		// sample ggx vndf distribution which gives a new normal
		vec3 halfVector = ggxDirection(
			wo,
			vec2( filteredRoughness ),
			rand2( 13 )
		);

		vec3 lightDirection = refract( normalize( - wo ), halfVector, eta );
		if ( surf.thinFilm ) {

			lightDirection = - refract( normalize( - lightDirection ), - vec3( 0.0, 0.0, 1.0 ), 1.0 / eta );

		}

		return normalize( lightDirection );

	}
	*/

	// TODO: This is just using a basic cosine-weighted specular distribution with an
	// incorrect PDF value at the moment. Update it to correctly use a GGX distribution
	float transmissionEval( vec3 wo, vec3 wi, vec3 wh, SurfaceRecord surf, inout vec3 color ) {

		color = surf.transmission * surf.color;

		// PDF
		// float F = evaluateFresnelWeight( dot( wo, wh ), surf.eta, surf.f0 );
		// float F = disneyFresnel( wo, wi, wh, surf.f0, surf.eta, surf.metalness );
		// if ( F >= 1.0 ) {

		// 	return 0.0;

		// }

		// return 1.0 / ( 1.0 - F );

		// reverted to previous to transmission. The above was causing black pixels
		float eta = surf.eta;
		float f0 = surf.f0;
		float cosTheta = min( wo.z, 1.0 );
		float sinTheta = sqrt( 1.0 - cosTheta * cosTheta );
		float reflectance = schlickFresnel( cosTheta, f0 );
		bool cannotRefract = eta * sinTheta > 1.0;
		if ( cannotRefract ) {

			return 0.0;

		}

		return 1.0 / ( 1.0 - reflectance );

	}

	vec3 transmissionDirection( vec3 wo, SurfaceRecord surf ) {

		float roughness = surf.filteredRoughness;
		float eta = surf.eta;
		vec3 halfVector = normalize( vec3( 0.0, 0.0, 1.0 ) + sampleSphere( rand2( 13 ) ) * roughness );
		vec3 lightDirection = refract( normalize( - wo ), halfVector, eta );

		if ( surf.thinFilm ) {

			lightDirection = - refract( normalize( - lightDirection ), - vec3( 0.0, 0.0, 1.0 ), 1.0 / eta );

		}
		return normalize( lightDirection );

	}

	// clearcoat
	float clearcoatEval( vec3 wo, vec3 wi, vec3 wh, SurfaceRecord surf, inout vec3 color ) {

		float ior = 1.5;
		float f0 = iorRatioToF0( ior );
		bool frontFace = surf.frontFace;
		float roughness = surf.filteredClearcoatRoughness;

		float eta = frontFace ? 1.0 / ior : ior;
		float G = ggxShadowMaskG2( wi, wo, roughness );
		float D = ggxDistribution( wh, roughness );
		float F = schlickFresnel( dot( wi, wh ), f0 );

		float fClearcoat = F * D * G / ( 4.0 * abs( wi.z * wo.z ) );
		color = color * ( 1.0 - surf.clearcoat * F ) + fClearcoat * surf.clearcoat * wi.z;

		// PDF
		// See equation (27) in http://jcgt.org/published/0003/02/03/
		return ggxPDF( wo, wh, roughness ) / ( 4.0 * dot( wi, wh ) );

	}

	vec3 clearcoatDirection( vec3 wo, SurfaceRecord surf ) {

		// sample ggx vndf distribution which gives a new normal
		float roughness = surf.filteredClearcoatRoughness;
		vec3 halfVector = ggxDirection(
			wo,
			vec2( roughness ),
			rand2( 14 )
		);

		// apply to new ray by reflecting off the new normal
		return - reflect( wo, halfVector );

	}

	// sheen
	vec3 sheenColor( vec3 wo, vec3 wi, vec3 wh, SurfaceRecord surf ) {

		float cosThetaO = saturateCos( wo.z );
		float cosThetaI = saturateCos( wi.z );
		float cosThetaH = wh.z;

		float D = velvetD( cosThetaH, surf.sheenRoughness );
		float G = velvetG( cosThetaO, cosThetaI, surf.sheenRoughness );

		// See equation (1) in http://www.aconty.com/pdf/s2017_pbs_imageworks_sheen.pdf
		vec3 color = surf.sheenColor;
		color *= D * G / ( 4.0 * abs( cosThetaO * cosThetaI ) );
		color *= wi.z;

		return color;

	}

	// bsdf
	void getLobeWeights(
		vec3 wo, vec3 wi, vec3 wh, vec3 clearcoatWo, SurfaceRecord surf,
		inout float diffuseWeight, inout float specularWeight, inout float transmissionWeight, inout float clearcoatWeight
	) {

		float metalness = surf.metalness;
		float transmission = surf.transmission;
		// float fEstimate = evaluateFresnelWeight( dot( wo, wh ), surf.eta, surf.f0 );
		float fEstimate = disneyFresnel( wo, wi, wh, surf.f0, surf.eta, surf.metalness );

		float transSpecularProb = mix( max( 0.25, fEstimate ), 1.0, metalness );
		float diffSpecularProb = 0.5 + 0.5 * metalness;

		diffuseWeight = ( 1.0 - transmission ) * ( 1.0 - diffSpecularProb );
		specularWeight = transmission * transSpecularProb + ( 1.0 - transmission ) * diffSpecularProb;
		transmissionWeight = transmission * ( 1.0 - transSpecularProb );
		clearcoatWeight = surf.clearcoat * schlickFresnel( clearcoatWo.z, 0.04 );

		float totalWeight = diffuseWeight + specularWeight + transmissionWeight + clearcoatWeight;
		diffuseWeight /= totalWeight;
		specularWeight /= totalWeight;
		transmissionWeight /= totalWeight;
		clearcoatWeight /= totalWeight;
	}

	float bsdfEval(
		vec3 wo, vec3 clearcoatWo, vec3 wi, vec3 clearcoatWi, SurfaceRecord surf,
		float diffuseWeight, float specularWeight, float transmissionWeight, float clearcoatWeight, inout float specularPdf, inout vec3 color
	) {

		float metalness = surf.metalness;
		float transmission = surf.transmission;

		float spdf = 0.0;
		float dpdf = 0.0;
		float tpdf = 0.0;
		float cpdf = 0.0;
		color = vec3( 0.0 );

		vec3 halfVector = getHalfVector( wi, wo, surf.eta );

		// diffuse
		if ( diffuseWeight > 0.0 && wi.z > 0.0 ) {

			dpdf = diffuseEval( wo, wi, halfVector, surf, color );
			color *= 1.0 - surf.transmission;

		}

		// ggx specular
		if ( specularWeight > 0.0 && wi.z > 0.0 ) {

			vec3 outColor;
			spdf = specularEval( wo, wi, getHalfVector( wi, wo ), surf, outColor );
			color += outColor;

		}

		// transmission
		if ( transmissionWeight > 0.0 && wi.z < 0.0 ) {

			tpdf = transmissionEval( wo, wi, halfVector, surf, color );

		}

		// sheen
		color *= mix( 1.0, sheenAlbedoScaling( wo, wi, surf ), surf.sheen );
		color += sheenColor( wo, wi, halfVector, surf ) * surf.sheen;

		// clearcoat
		if ( clearcoatWi.z >= 0.0 && clearcoatWeight > 0.0 ) {

			vec3 clearcoatHalfVector = getHalfVector( clearcoatWo, clearcoatWi );
			cpdf = clearcoatEval( clearcoatWo, clearcoatWi, clearcoatHalfVector, surf, color );

		}

		float pdf =
			dpdf * diffuseWeight
			+ spdf * specularWeight
			+ tpdf * transmissionWeight
			+ cpdf * clearcoatWeight;

		// retrieve specular rays for the shadows flag
		specularPdf = spdf * specularWeight + cpdf * clearcoatWeight;

		return pdf;

	}

	float bsdfResult( vec3 worldWo, vec3 worldWi, SurfaceRecord surf, inout vec3 color ) {

		if ( surf.volumeParticle ) {

			color = surf.color / ( 4.0 * PI );
			return 1.0 / ( 4.0 * PI );

		}

		vec3 wo = normalize( surf.normalInvBasis * worldWo );
		vec3 wi = normalize( surf.normalInvBasis * worldWi );

		vec3 clearcoatWo = normalize( surf.clearcoatInvBasis * worldWo );
		vec3 clearcoatWi = normalize( surf.clearcoatInvBasis * worldWi );

		vec3 wh = getHalfVector( wo, wi, surf.eta );
		float diffuseWeight;
		float specularWeight;
		float transmissionWeight;
		float clearcoatWeight;
		getLobeWeights( wo, wi, wh, clearcoatWo, surf, diffuseWeight, specularWeight, transmissionWeight, clearcoatWeight );

		float specularPdf;
		return bsdfEval( wo, clearcoatWo, wi, clearcoatWi, surf, diffuseWeight, specularWeight, transmissionWeight, clearcoatWeight, specularPdf, color );

	}

	ScatterRecord bsdfSample( vec3 worldWo, SurfaceRecord surf ) {

		if ( surf.volumeParticle ) {

			ScatterRecord sampleRec;
			sampleRec.specularPdf = 0.0;
			sampleRec.pdf = 1.0 / ( 4.0 * PI );
			sampleRec.direction = sampleSphere( rand2( 16 ) );
			sampleRec.color = surf.color / ( 4.0 * PI );
			return sampleRec;

		}

		vec3 wo = normalize( surf.normalInvBasis * worldWo );
		vec3 clearcoatWo = normalize( surf.clearcoatInvBasis * worldWo );
		mat3 normalBasis = surf.normalBasis;
		mat3 invBasis = surf.normalInvBasis;
		mat3 clearcoatNormalBasis = surf.clearcoatBasis;
		mat3 clearcoatInvBasis = surf.clearcoatInvBasis;

		float diffuseWeight;
		float specularWeight;
		float transmissionWeight;
		float clearcoatWeight;
		// using normal and basically-reflected ray since we don't have proper half vector here
		getLobeWeights( wo, wo, vec3( 0, 0, 1 ), clearcoatWo, surf, diffuseWeight, specularWeight, transmissionWeight, clearcoatWeight );

		float pdf[4];
		pdf[0] = diffuseWeight;
		pdf[1] = specularWeight;
		pdf[2] = transmissionWeight;
		pdf[3] = clearcoatWeight;

		float cdf[4];
		cdf[0] = pdf[0];
		cdf[1] = pdf[1] + cdf[0];
		cdf[2] = pdf[2] + cdf[1];
		cdf[3] = pdf[3] + cdf[2];

		if( cdf[3] != 0.0 ) {

			float invMaxCdf = 1.0 / cdf[3];
			cdf[0] *= invMaxCdf;
			cdf[1] *= invMaxCdf;
			cdf[2] *= invMaxCdf;
			cdf[3] *= invMaxCdf;

		} else {

			cdf[0] = 1.0;
			cdf[1] = 0.0;
			cdf[2] = 0.0;
			cdf[3] = 0.0;

		}

		vec3 wi;
		vec3 clearcoatWi;

		float r = rand( 15 );
		if ( r <= cdf[0] ) { // diffuse

			wi = diffuseDirection( wo, surf );
			clearcoatWi = normalize( clearcoatInvBasis * normalize( normalBasis * wi ) );

		} else if ( r <= cdf[1] ) { // specular

			wi = specularDirection( wo, surf );
			clearcoatWi = normalize( clearcoatInvBasis * normalize( normalBasis * wi ) );

		} else if ( r <= cdf[2] ) { // transmission / refraction

			wi = transmissionDirection( wo, surf );
			clearcoatWi = normalize( clearcoatInvBasis * normalize( normalBasis * wi ) );

		} else if ( r <= cdf[3] ) { // clearcoat

			clearcoatWi = clearcoatDirection( clearcoatWo, surf );
			wi = normalize( invBasis * normalize( clearcoatNormalBasis * clearcoatWi ) );

		}

		ScatterRecord result;
		result.pdf = bsdfEval( wo, clearcoatWo, wi, clearcoatWi, surf, diffuseWeight, specularWeight, transmissionWeight, clearcoatWeight, result.specularPdf, result.color );
		result.direction = normalize( surf.normalBasis * wi );

		return result;

	}

`;var jp=`

	// returns the hit distance given the material density
	float intersectFogVolume( Material material, float u ) {

		// https://raytracing.github.io/books/RayTracingTheNextWeek.html#volumes/constantdensitymediums
		return material.opacity == 0.0 ? INFINITY : ( - 1.0 / material.opacity ) * log( u );

	}

	ScatterRecord sampleFogVolume( SurfaceRecord surf, vec2 uv ) {

		ScatterRecord sampleRec;
		sampleRec.specularPdf = 0.0;
		sampleRec.pdf = 1.0 / ( 2.0 * PI );
		sampleRec.direction = sampleSphere( uv );
		sampleRec.color = surf.color;
		return sampleRec;

	}

`;var em=`

	// The GGX functions provide sampling and distribution information for normals as output so
	// in order to get probability of scatter direction the half vector must be computed and provided.
	// [0] https://www.cs.cornell.edu/~srm/publications/EGSR07-btdf.pdf
	// [1] https://hal.archives-ouvertes.fr/hal-01509746/document
	// [2] http://jcgt.org/published/0007/04/01/
	// [4] http://jcgt.org/published/0003/02/03/

	// trowbridge-reitz === GGX === GTR

	vec3 ggxDirection( vec3 incidentDir, vec2 roughness, vec2 uv ) {

		// TODO: try GGXVNDF implementation from reference [2], here. Needs to update ggxDistribution
		// function below, as well

		// Implementation from reference [1]
		// stretch view
		vec3 V = normalize( vec3( roughness * incidentDir.xy, incidentDir.z ) );

		// orthonormal basis
		vec3 T1 = ( V.z < 0.9999 ) ? normalize( cross( V, vec3( 0.0, 0.0, 1.0 ) ) ) : vec3( 1.0, 0.0, 0.0 );
		vec3 T2 = cross( T1, V );

		// sample point with polar coordinates (r, phi)
		float a = 1.0 / ( 1.0 + V.z );
		float r = sqrt( uv.x );
		float phi = ( uv.y < a ) ? uv.y / a * PI : PI + ( uv.y - a ) / ( 1.0 - a ) * PI;
		float P1 = r * cos( phi );
		float P2 = r * sin( phi ) * ( ( uv.y < a ) ? 1.0 : V.z );

		// compute normal
		vec3 N = P1 * T1 + P2 * T2 + V * sqrt( max( 0.0, 1.0 - P1 * P1 - P2 * P2 ) );

		// unstretch
		N = normalize( vec3( roughness * N.xy, max( 0.0, N.z ) ) );

		return N;

	}

	// Below are PDF and related functions for use in a Monte Carlo path tracer
	// as specified in Appendix B of the following paper
	// See equation (34) from reference [0]
	float ggxLamda( float theta, float roughness ) {

		float tanTheta = tan( theta );
		float tanTheta2 = tanTheta * tanTheta;
		float alpha2 = roughness * roughness;

		float numerator = - 1.0 + sqrt( 1.0 + alpha2 * tanTheta2 );
		return numerator / 2.0;

	}

	// See equation (34) from reference [0]
	float ggxShadowMaskG1( float theta, float roughness ) {

		return 1.0 / ( 1.0 + ggxLamda( theta, roughness ) );

	}

	// See equation (125) from reference [4]
	float ggxShadowMaskG2( vec3 wi, vec3 wo, float roughness ) {

		float incidentTheta = acos( wi.z );
		float scatterTheta = acos( wo.z );
		return 1.0 / ( 1.0 + ggxLamda( incidentTheta, roughness ) + ggxLamda( scatterTheta, roughness ) );

	}

	// See equation (33) from reference [0]
	float ggxDistribution( vec3 halfVector, float roughness ) {

		float a2 = roughness * roughness;
		a2 = max( EPSILON, a2 );
		float cosTheta = halfVector.z;
		float cosTheta4 = pow( cosTheta, 4.0 );

		if ( cosTheta == 0.0 ) return 0.0;

		float theta = acosSafe( halfVector.z );
		float tanTheta = tan( theta );
		float tanTheta2 = pow( tanTheta, 2.0 );

		float denom = PI * cosTheta4 * pow( a2 + tanTheta2, 2.0 );
		return ( a2 / denom );

	}

	// See equation (3) from reference [2]
	float ggxPDF( vec3 wi, vec3 halfVector, float roughness ) {

		float incidentTheta = acos( wi.z );
		float D = ggxDistribution( halfVector, roughness );
		float G1 = ggxShadowMaskG1( incidentTheta, roughness );

		return D * G1 * max( 0.0, dot( wi, halfVector ) ) / wi.z;

	}

`;var tm=`

	// XYZ to sRGB color space
	const mat3 XYZ_TO_REC709 = mat3(
		3.2404542, -0.9692660,  0.0556434,
		-1.5371385,  1.8760108, -0.2040259,
		-0.4985314,  0.0415560,  1.0572252
	);

	vec3 fresnel0ToIor( vec3 fresnel0 ) {

		vec3 sqrtF0 = sqrt( fresnel0 );
		return ( vec3( 1.0 ) + sqrtF0 ) / ( vec3( 1.0 ) - sqrtF0 );

	}

	// Conversion FO/IOR
	vec3 iorToFresnel0( vec3 transmittedIor, float incidentIor ) {

		return square( ( transmittedIor - vec3( incidentIor ) ) / ( transmittedIor + vec3( incidentIor ) ) );

	}

	// ior is a value between 1.0 and 3.0. 1.0 is air interface
	float iorToFresnel0( float transmittedIor, float incidentIor ) {

		return square( ( transmittedIor - incidentIor ) / ( transmittedIor + incidentIor ) );

	}

	// Fresnel equations for dielectric/dielectric interfaces. See https://belcour.github.io/blog/research/2017/05/01/brdf-thin-film.html
	vec3 evalSensitivity( float OPD, vec3 shift ) {

		float phase = 2.0 * PI * OPD * 1.0e-9;

		vec3 val = vec3( 5.4856e-13, 4.4201e-13, 5.2481e-13 );
		vec3 pos = vec3( 1.6810e+06, 1.7953e+06, 2.2084e+06 );
		vec3 var = vec3( 4.3278e+09, 9.3046e+09, 6.6121e+09 );

		vec3 xyz = val * sqrt( 2.0 * PI * var ) * cos( pos * phase + shift ) * exp( - square( phase ) * var );
		xyz.x += 9.7470e-14 * sqrt( 2.0 * PI * 4.5282e+09 ) * cos( 2.2399e+06 * phase + shift[ 0 ] ) * exp( - 4.5282e+09 * square( phase ) );
		xyz /= 1.0685e-7;

		vec3 srgb = XYZ_TO_REC709 * xyz;
		return srgb;

	}

	// See Section 4. Analytic Spectral Integration, A Practical Extension to Microfacet Theory for the Modeling of Varying Iridescence, https://hal.archives-ouvertes.fr/hal-01518344/document
	vec3 evalIridescence( float outsideIOR, float eta2, float cosTheta1, float thinFilmThickness, vec3 baseF0 ) {

		vec3 I;

		// Force iridescenceIor -> outsideIOR when thinFilmThickness -> 0.0
		float iridescenceIor = mix( outsideIOR, eta2, smoothstep( 0.0, 0.03, thinFilmThickness ) );

		// Evaluate the cosTheta on the base layer (Snell law)
		float sinTheta2Sq = square( outsideIOR / iridescenceIor ) * ( 1.0 - square( cosTheta1 ) );

		// Handle TIR:
		float cosTheta2Sq = 1.0 - sinTheta2Sq;
		if ( cosTheta2Sq < 0.0 ) {

			return vec3( 1.0 );

		}

		float cosTheta2 = sqrt( cosTheta2Sq );

		// First interface
		float R0 = iorToFresnel0( iridescenceIor, outsideIOR );
		float R12 = schlickFresnel( cosTheta1, R0 );
		float R21 = R12;
		float T121 = 1.0 - R12;
		float phi12 = 0.0;
		if ( iridescenceIor < outsideIOR ) {

			phi12 = PI;

		}

		float phi21 = PI - phi12;

		// Second interface
		vec3 baseIOR = fresnel0ToIor( clamp( baseF0, 0.0, 0.9999 ) ); // guard against 1.0
		vec3 R1 = iorToFresnel0( baseIOR, iridescenceIor );
		vec3 R23 = schlickFresnel( cosTheta2, R1 );
		vec3 phi23 = vec3( 0.0 );
		if ( baseIOR[0] < iridescenceIor ) {

			phi23[ 0 ] = PI;

		}

		if ( baseIOR[1] < iridescenceIor ) {

			phi23[ 1 ] = PI;

		}

		if ( baseIOR[2] < iridescenceIor ) {

			phi23[ 2 ] = PI;

		}

		// Phase shift
		float OPD = 2.0 * iridescenceIor * thinFilmThickness * cosTheta2;
		vec3 phi = vec3( phi21 ) + phi23;

		// Compound terms
		vec3 R123 = clamp( R12 * R23, 1e-5, 0.9999 );
		vec3 r123 = sqrt( R123 );
		vec3 Rs = square( T121 ) * R23 / ( vec3( 1.0 ) - R123 );

		// Reflectance term for m = 0 (DC term amplitude)
		vec3 C0 = R12 + Rs;
		I = C0;

		// Reflectance term for m > 0 (pairs of diracs)
		vec3 Cm = Rs - T121;
		for ( int m = 1; m <= 2; ++ m ) {

			Cm *= r123;
			vec3 Sm = 2.0 * evalSensitivity( float( m ) * OPD, float( m ) * phi );
			I += Cm * Sm;

		}

		// Since out of gamut colors might be produced, negative color values are clamped to 0.
		return max( I, vec3( 0.0 ) );

	}

`;var nm=`

	// See equation (2) in http://www.aconty.com/pdf/s2017_pbs_imageworks_sheen.pdf
	float velvetD( float cosThetaH, float roughness ) {

		float alpha = max( roughness, 0.07 );
		alpha = alpha * alpha;

		float invAlpha = 1.0 / alpha;

		float sqrCosThetaH = cosThetaH * cosThetaH;
		float sinThetaH = max( 1.0 - sqrCosThetaH, 0.001 );

		return ( 2.0 + invAlpha ) * pow( sinThetaH, 0.5 * invAlpha ) / ( 2.0 * PI );

	}

	float velvetParamsInterpolate( int i, float oneMinusAlphaSquared ) {

		const float p0[5] = float[5]( 25.3245, 3.32435, 0.16801, -1.27393, -4.85967 );
		const float p1[5] = float[5]( 21.5473, 3.82987, 0.19823, -1.97760, -4.32054 );

		return mix( p1[i], p0[i], oneMinusAlphaSquared );

	}

	float velvetL( float x, float alpha ) {

		float oneMinusAlpha = 1.0 - alpha;
		float oneMinusAlphaSquared = oneMinusAlpha * oneMinusAlpha;

		float a = velvetParamsInterpolate( 0, oneMinusAlphaSquared );
		float b = velvetParamsInterpolate( 1, oneMinusAlphaSquared );
		float c = velvetParamsInterpolate( 2, oneMinusAlphaSquared );
		float d = velvetParamsInterpolate( 3, oneMinusAlphaSquared );
		float e = velvetParamsInterpolate( 4, oneMinusAlphaSquared );

		return a / ( 1.0 + b * pow( abs( x ), c ) ) + d * x + e;

	}

	// See equation (3) in http://www.aconty.com/pdf/s2017_pbs_imageworks_sheen.pdf
	float velvetLambda( float cosTheta, float alpha ) {

		return abs( cosTheta ) < 0.5 ? exp( velvetL( cosTheta, alpha ) ) : exp( 2.0 * velvetL( 0.5, alpha ) - velvetL( 1.0 - cosTheta, alpha ) );

	}

	// See Section 3, Shadowing Term, in http://www.aconty.com/pdf/s2017_pbs_imageworks_sheen.pdf
	float velvetG( float cosThetaO, float cosThetaI, float roughness ) {

		float alpha = max( roughness, 0.07 );
		alpha = alpha * alpha;

		return 1.0 / ( 1.0 + velvetLambda( cosThetaO, alpha ) + velvetLambda( cosThetaI, alpha ) );

	}

	float directionalAlbedoSheen( float cosTheta, float alpha ) {

		cosTheta = saturate( cosTheta );

		float c = 1.0 - cosTheta;
		float c3 = c * c * c;

		return 0.65584461 * c3 + 1.0 / ( 4.16526551 + exp( -7.97291361 * sqrt( alpha ) + 6.33516894 ) );

	}

	float sheenAlbedoScaling( vec3 wo, vec3 wi, SurfaceRecord surf ) {

		float alpha = max( surf.sheenRoughness, 0.07 );
		alpha = alpha * alpha;

		float maxSheenColor = max( max( surf.sheenColor.r, surf.sheenColor.g ), surf.sheenColor.b );

		float eWo = directionalAlbedoSheen( saturateCos( wo.z ), alpha );
		float eWi = directionalAlbedoSheen( saturateCos( wi.z ), alpha );

		return min( 1.0 - maxSheenColor * eWo, 1.0 - maxSheenColor * eWi );

	}

	// See Section 5, Layering, in http://www.aconty.com/pdf/s2017_pbs_imageworks_sheen.pdf
	float sheenAlbedoScaling( vec3 wo, SurfaceRecord surf ) {

		float alpha = max( surf.sheenRoughness, 0.07 );
		alpha = alpha * alpha;

		float maxSheenColor = max( max( surf.sheenColor.r, surf.sheenColor.g ), surf.sheenColor.b );

		float eWo = directionalAlbedoSheen( saturateCos( wo.z ), alpha );

		return 1.0 - maxSheenColor * eWo;

	}

`;var im=`

#ifndef FOG_CHECK_ITERATIONS
#define FOG_CHECK_ITERATIONS 30
#endif

// returns whether the given material is a fog material or not
bool isMaterialFogVolume( sampler2D materials, uint materialIndex ) {

	uint i = materialIndex * uint( MATERIAL_PIXELS );
	vec4 s14 = texelFetch1D( materials, i + 14u );
	return bool( int( s14.b ) & 4 );

}

// returns true if we're within the first fog volume we hit
bool bvhIntersectFogVolumeHit(
	vec3 rayOrigin, vec3 rayDirection,
	usampler2D materialIndexAttribute, sampler2D materials,
	inout Material material
) {

	material.fogVolume = false;

	for ( int i = 0; i < FOG_CHECK_ITERATIONS; i ++ ) {

		// find nearest hit
		uvec4 faceIndices = uvec4( 0u );
		vec3 faceNormal = vec3( 0.0, 0.0, 1.0 );
		vec3 barycoord = vec3( 0.0 );
		float side = 1.0;
		float dist = 0.0;
		bool hit = bvhIntersectFirstHit( bvh, rayOrigin, rayDirection, faceIndices, faceNormal, barycoord, side, dist );
		if ( hit ) {

			// if it's a fog volume return whether we hit the front or back face
			uint materialIndex = uTexelFetch1D( materialIndexAttribute, faceIndices.x ).r;
			if ( isMaterialFogVolume( materials, materialIndex ) ) {

				material = readMaterialInfo( materials, materialIndex );
				return side == - 1.0;

			} else {

				// move the ray forward
				rayOrigin = stepRayOrigin( rayOrigin, rayDirection, - faceNormal, dist );

			}

		} else {

			return false;

		}

	}

	return false;

}

`;var rm=`

	// step through multiple surface hits and accumulate color attenuation based on transmissive surfaces
	// returns true if a solid surface was hit
	bool attenuateHit(
		RenderState state,
		Ray ray, float rayDist,
		out vec3 color
	) {

		// store the original bounce index so we can reset it after
		uint originalBounceIndex = sobolBounceIndex;

		int traversals = state.traversals;
		int transmissiveTraversals = state.transmissiveTraversals;
		bool isShadowRay = state.isShadowRay;
		Material fogMaterial = state.fogMaterial;

		vec3 startPoint = ray.origin;

		// hit results
		SurfaceHit surfaceHit;

		color = vec3( 1.0 );

		bool result = true;
		for ( int i = 0; i < traversals; i ++ ) {

			sobolBounceIndex ++;

			int hitType = traceScene( ray, fogMaterial, surfaceHit );

			if ( hitType == FOG_HIT ) {

				result = true;
				break;

			} else if ( hitType == SURFACE_HIT ) {

				float totalDist = distance( startPoint, ray.origin + ray.direction * surfaceHit.dist );
				if ( totalDist > rayDist ) {

					result = false;
					break;

				}

				// TODO: attenuate the contribution based on the PDF of the resulting ray including refraction values
				// Should be able to work using the material BSDF functions which will take into account specularity, etc.
				// TODO: should we account for emissive surfaces here?

				uint materialIndex = uTexelFetch1D( materialIndexAttribute, surfaceHit.faceIndices.x ).r;
				Material material = readMaterialInfo( materials, materialIndex );

				// adjust the ray to the new surface
				bool isEntering = surfaceHit.side == 1.0;
				ray.origin = stepRayOrigin( ray.origin, ray.direction, - surfaceHit.faceNormal, surfaceHit.dist );

				#if FEATURE_FOG

				if ( material.fogVolume ) {

					fogMaterial = material;
					fogMaterial.fogVolume = surfaceHit.side == 1.0;
					i -= sign( transmissiveTraversals );
					transmissiveTraversals --;
					continue;

				}

				#endif

				if ( ! material.castShadow && isShadowRay ) {

					continue;

				}

				vec2 uv = textureSampleBarycoord( attributesArray, ATTR_UV, surfaceHit.barycoord, surfaceHit.faceIndices.xyz ).xy;
				vec4 vertexColor = textureSampleBarycoord( attributesArray, ATTR_COLOR, surfaceHit.barycoord, surfaceHit.faceIndices.xyz );

				// albedo
				vec4 albedo = vec4( material.color, material.opacity );
				if ( material.map != - 1 ) {

					vec3 uvPrime = material.mapTransform * vec3( uv, 1 );
					albedo *= texture2D( textures, vec3( uvPrime.xy, material.map ) );

				}

				if ( material.vertexColors ) {

					albedo *= vertexColor;

				}

				// alphaMap
				if ( material.alphaMap != - 1 ) {

					vec3 uvPrime = material.alphaMapTransform * vec3( uv, 1 );
					albedo.a *= texture2D( textures, vec3( uvPrime.xy, material.alphaMap ) ).x;

				}

				// transmission
				float transmission = material.transmission;
				if ( material.transmissionMap != - 1 ) {

					vec3 uvPrime = material.transmissionMapTransform * vec3( uv, 1 );
					transmission *= texture2D( textures, vec3( uvPrime.xy, material.transmissionMap ) ).r;

				}

				// metalness
				float metalness = material.metalness;
				if ( material.metalnessMap != - 1 ) {

					vec3 uvPrime = material.metalnessMapTransform * vec3( uv, 1 );
					metalness *= texture2D( textures, vec3( uvPrime.xy, material.metalnessMap ) ).b;

				}

				float alphaTest = material.alphaTest;
				bool useAlphaTest = alphaTest != 0.0;
				float transmissionFactor = ( 1.0 - metalness ) * transmission;
				if (
					transmissionFactor < rand( 9 ) && ! (
						// material sidedness
						material.side != 0.0 && surfaceHit.side == material.side

						// alpha test
						|| useAlphaTest && albedo.a < alphaTest

						// opacity
						|| material.transparent && ! useAlphaTest && albedo.a < rand( 10 )
					)
				) {

					result = true;
					break;

				}

				if ( surfaceHit.side == 1.0 && isEntering ) {

					// only attenuate by surface color on the way in
					color *= mix( vec3( 1.0 ), albedo.rgb, transmissionFactor );

				} else if ( surfaceHit.side == - 1.0 ) {

					// attenuate by medium once we hit the opposite side of the model
					color *= transmissionAttenuation( surfaceHit.dist, material.attenuationColor, material.attenuationDistance );

				}

				bool isTransmissiveRay = dot( ray.direction, surfaceHit.faceNormal * surfaceHit.side ) < 0.0;
				if ( ( isTransmissiveRay || isEntering ) && transmissiveTraversals > 0 ) {

					i -= sign( transmissiveTraversals );
					transmissiveTraversals --;

				}

			} else {

				result = false;
				break;

			}

		}

		// reset the bounce index
		sobolBounceIndex = originalBounceIndex;
		return result;

	}

`;var sm=`

	vec3 ndcToRayOrigin( vec2 coord ) {

		vec4 rayOrigin4 = cameraWorldMatrix * invProjectionMatrix * vec4( coord, - 1.0, 1.0 );
		return rayOrigin4.xyz / rayOrigin4.w;
	}

	Ray getCameraRay() {

		vec2 ssd = vec2( 1.0 ) / resolution;

		// Jitter the camera ray by finding a uv coordinate at a random sample
		// around this pixel's UV coordinate for AA
		vec2 ruv = rand2( 0 );
		vec2 jitteredUv = vUv + vec2( tentFilter( ruv.x ) * ssd.x, tentFilter( ruv.y ) * ssd.y );
		Ray ray;

		#if CAMERA_TYPE == 2

			// Equirectangular projection
			vec4 rayDirection4 = vec4( equirectUvToDirection( jitteredUv ), 0.0 );
			vec4 rayOrigin4 = vec4( 0.0, 0.0, 0.0, 1.0 );

			rayDirection4 = cameraWorldMatrix * rayDirection4;
			rayOrigin4 = cameraWorldMatrix * rayOrigin4;

			ray.direction = normalize( rayDirection4.xyz );
			ray.origin = rayOrigin4.xyz / rayOrigin4.w;

		#else

			// get [- 1, 1] normalized device coordinates
			vec2 ndc = 2.0 * jitteredUv - vec2( 1.0 );
			ray.origin = ndcToRayOrigin( ndc );

			#if CAMERA_TYPE == 1

				// Orthographic projection
				ray.direction = ( cameraWorldMatrix * vec4( 0.0, 0.0, - 1.0, 0.0 ) ).xyz;
				ray.direction = normalize( ray.direction );

			#else

				// Perspective projection
				ray.direction = normalize( mat3( cameraWorldMatrix ) * ( invProjectionMatrix * vec4( ndc, 0.0, 1.0 ) ).xyz );

			#endif

		#endif

		#if FEATURE_DOF
		{

			// depth of field
			vec3 focalPoint = ray.origin + normalize( ray.direction ) * physicalCamera.focusDistance;

			// get the aperture sample
			// if blades === 0 then we assume a circle
			vec3 shapeUVW= rand3( 1 );
			int blades = physicalCamera.apertureBlades;
			float anamorphicRatio = physicalCamera.anamorphicRatio;
			vec2 apertureSample = sampleAperture( blades, shapeUVW );
			apertureSample *= physicalCamera.bokehSize * 0.5 * 1e-3;

			// rotate the aperture shape
			apertureSample =
				rotateVector( apertureSample, physicalCamera.apertureRotation ) *
				saturate( vec2( anamorphicRatio, 1.0 / anamorphicRatio ) );

			// create the new ray
			ray.origin += ( cameraWorldMatrix * vec4( apertureSample, 0.0, 0.0 ) ).xyz;
			ray.direction = focalPoint - ray.origin;

		}
		#endif

		ray.direction = normalize( ray.direction );

		return ray;

	}

`;var am=`

	vec3 directLightContribution( vec3 worldWo, SurfaceRecord surf, RenderState state, vec3 rayOrigin ) {

		vec3 result = vec3( 0.0 );

		// uniformly pick a light or environment map
		if( lightsDenom != 0.0 && rand( 5 ) < float( lights.count ) / lightsDenom ) {

			// sample a light or environment
			LightRecord lightRec = randomLightSample( lights.tex, iesProfiles, lights.count, rayOrigin, rand3( 6 ) );

			bool isSampleBelowSurface = ! surf.volumeParticle && dot( surf.faceNormal, lightRec.direction ) < 0.0;
			if ( isSampleBelowSurface ) {

				lightRec.pdf = 0.0;

			}

			// check if a ray could even reach the light area
			Ray lightRay;
			lightRay.origin = rayOrigin;
			lightRay.direction = lightRec.direction;
			vec3 attenuatedColor;
			if (
				lightRec.pdf > 0.0 &&
				isDirectionValid( lightRec.direction, surf.normal, surf.faceNormal ) &&
				! attenuateHit( state, lightRay, lightRec.dist, attenuatedColor )
			) {

				// get the material pdf
				vec3 sampleColor;
				float lightMaterialPdf = bsdfResult( worldWo, lightRec.direction, surf, sampleColor );
				bool isValidSampleColor = all( greaterThanEqual( sampleColor, vec3( 0.0 ) ) );
				if ( lightMaterialPdf > 0.0 && isValidSampleColor ) {

					// weight the direct light contribution
					float lightPdf = lightRec.pdf / lightsDenom;
					float misWeight = lightRec.type == SPOT_LIGHT_TYPE || lightRec.type == DIR_LIGHT_TYPE || lightRec.type == POINT_LIGHT_TYPE ? 1.0 : misHeuristic( lightPdf, lightMaterialPdf );
					result = attenuatedColor * lightRec.emission * state.throughputColor * sampleColor * misWeight / lightPdf;

				}

			}

		} else if ( envMapInfo.totalSum != 0.0 && environmentIntensity != 0.0 ) {

			// find a sample in the environment map to include in the contribution
			vec3 envColor, envDirection;
			float envPdf = sampleEquirectProbability( rand2( 7 ), envColor, envDirection );
			envDirection = invEnvRotation3x3 * envDirection;

			// this env sampling is not set up for transmissive sampling and yields overly bright
			// results so we ignore the sample in this case.
			// TODO: this should be improved but how? The env samples could traverse a few layers?
			bool isSampleBelowSurface = ! surf.volumeParticle && dot( surf.faceNormal, envDirection ) < 0.0;
			if ( isSampleBelowSurface ) {

				envPdf = 0.0;

			}

			// check if a ray could even reach the surface
			Ray envRay;
			envRay.origin = rayOrigin;
			envRay.direction = envDirection;
			vec3 attenuatedColor;
			if (
				envPdf > 0.0 &&
				isDirectionValid( envDirection, surf.normal, surf.faceNormal ) &&
				! attenuateHit( state, envRay, INFINITY, attenuatedColor )
			) {

				// get the material pdf
				vec3 sampleColor;
				float envMaterialPdf = bsdfResult( worldWo, envDirection, surf, sampleColor );
				bool isValidSampleColor = all( greaterThanEqual( sampleColor, vec3( 0.0 ) ) );
				if ( envMaterialPdf > 0.0 && isValidSampleColor ) {

					// weight the direct light contribution
					envPdf /= lightsDenom;
					float misWeight = misHeuristic( envPdf, envMaterialPdf );
					result = attenuatedColor * environmentIntensity * envColor * state.throughputColor * sampleColor * misWeight / envPdf;

				}

			}

		}

		// Function changed to have a single return statement to potentially help with crashes on Mac OS.
		// See issue #470
		return result;

	}

`;var om=`

	#define SKIP_SURFACE 0
	#define HIT_SURFACE 1
	int getSurfaceRecord(
		Material material, SurfaceHit surfaceHit, sampler2DArray attributesArray,
		float accumulatedRoughness,
		inout SurfaceRecord surf
	) {

		if ( material.fogVolume ) {

			vec3 normal = vec3( 0, 0, 1 );

			SurfaceRecord fogSurface;
			fogSurface.volumeParticle = true;
			fogSurface.color = material.color;
			fogSurface.emission = material.emissiveIntensity * material.emissive;
			fogSurface.normal = normal;
			fogSurface.faceNormal = normal;
			fogSurface.clearcoatNormal = normal;

			surf = fogSurface;
			return HIT_SURFACE;

		}

		// uv coord for textures
		vec2 uv = textureSampleBarycoord( attributesArray, ATTR_UV, surfaceHit.barycoord, surfaceHit.faceIndices.xyz ).xy;
		vec4 vertexColor = textureSampleBarycoord( attributesArray, ATTR_COLOR, surfaceHit.barycoord, surfaceHit.faceIndices.xyz );

		// albedo
		vec4 albedo = vec4( material.color, material.opacity );
		if ( material.map != - 1 ) {

			vec3 uvPrime = material.mapTransform * vec3( uv, 1 );
			albedo *= texture2D( textures, vec3( uvPrime.xy, material.map ) );

		}

		if ( material.vertexColors ) {

			albedo *= vertexColor;

		}

		// alphaMap
		if ( material.alphaMap != - 1 ) {

			vec3 uvPrime = material.alphaMapTransform * vec3( uv, 1 );
			albedo.a *= texture2D( textures, vec3( uvPrime.xy, material.alphaMap ) ).x;

		}

		// possibly skip this sample if it's transparent, alpha test is enabled, or we hit the wrong material side
		// and it's single sided.
		// - alpha test is disabled when it === 0
		// - the material sidedness test is complicated because we want light to pass through the back side but still
		// be able to see the front side. This boolean checks if the side we hit is the front side on the first ray
		// and we're rendering the other then we skip it. Do the opposite on subsequent bounces to get incoming light.
		float alphaTest = material.alphaTest;
		bool useAlphaTest = alphaTest != 0.0;
		if (
			// material sidedness
			material.side != 0.0 && surfaceHit.side != material.side

			// alpha test
			|| useAlphaTest && albedo.a < alphaTest

			// opacity
			|| material.transparent && ! useAlphaTest && albedo.a < rand( 3 )
		) {

			return SKIP_SURFACE;

		}

		// fetch the interpolated smooth normal
		vec3 normal = normalize( textureSampleBarycoord(
			attributesArray,
			ATTR_NORMAL,
			surfaceHit.barycoord,
			surfaceHit.faceIndices.xyz
		).xyz );

		// roughness
		float roughness = material.roughness;
		if ( material.roughnessMap != - 1 ) {

			vec3 uvPrime = material.roughnessMapTransform * vec3( uv, 1 );
			roughness *= texture2D( textures, vec3( uvPrime.xy, material.roughnessMap ) ).g;

		}

		// metalness
		float metalness = material.metalness;
		if ( material.metalnessMap != - 1 ) {

			vec3 uvPrime = material.metalnessMapTransform * vec3( uv, 1 );
			metalness *= texture2D( textures, vec3( uvPrime.xy, material.metalnessMap ) ).b;

		}

		// emission
		vec3 emission = material.emissiveIntensity * material.emissive;
		if ( material.emissiveMap != - 1 ) {

			vec3 uvPrime = material.emissiveMapTransform * vec3( uv, 1 );
			emission *= texture2D( textures, vec3( uvPrime.xy, material.emissiveMap ) ).xyz;

		}

		// transmission
		float transmission = material.transmission;
		if ( material.transmissionMap != - 1 ) {

			vec3 uvPrime = material.transmissionMapTransform * vec3( uv, 1 );
			transmission *= texture2D( textures, vec3( uvPrime.xy, material.transmissionMap ) ).r;

		}

		// normal
		if ( material.flatShading ) {

			// if we're rendering a flat shaded object then use the face normals - the face normal
			// is provided based on the side the ray hits the mesh so flip it to align with the
			// interpolated vertex normals.
			normal = surfaceHit.faceNormal * surfaceHit.side;

		}

		vec3 baseNormal = normal;
		if ( material.normalMap != - 1 ) {

			vec4 tangentSample = textureSampleBarycoord(
				attributesArray,
				ATTR_TANGENT,
				surfaceHit.barycoord,
				surfaceHit.faceIndices.xyz
			);

			// some provided tangents can be malformed (0, 0, 0) causing the normal to be degenerate
			// resulting in NaNs and slow path tracing.
			if ( length( tangentSample.xyz ) > 0.0 ) {

				vec3 tangent = normalize( tangentSample.xyz );
				vec3 bitangent = normalize( cross( normal, tangent ) * tangentSample.w );
				mat3 vTBN = mat3( tangent, bitangent, normal );

				vec3 uvPrime = material.normalMapTransform * vec3( uv, 1 );
				vec3 texNormal = texture2D( textures, vec3( uvPrime.xy, material.normalMap ) ).xyz * 2.0 - 1.0;
				texNormal.xy *= material.normalScale;
				normal = vTBN * texNormal;

			}

		}

		normal *= surfaceHit.side;

		// clearcoat
		float clearcoat = material.clearcoat;
		if ( material.clearcoatMap != - 1 ) {

			vec3 uvPrime = material.clearcoatMapTransform * vec3( uv, 1 );
			clearcoat *= texture2D( textures, vec3( uvPrime.xy, material.clearcoatMap ) ).r;

		}

		// clearcoatRoughness
		float clearcoatRoughness = material.clearcoatRoughness;
		if ( material.clearcoatRoughnessMap != - 1 ) {

			vec3 uvPrime = material.clearcoatRoughnessMapTransform * vec3( uv, 1 );
			clearcoatRoughness *= texture2D( textures, vec3( uvPrime.xy, material.clearcoatRoughnessMap ) ).g;

		}

		// clearcoatNormal
		vec3 clearcoatNormal = baseNormal;
		if ( material.clearcoatNormalMap != - 1 ) {

			vec4 tangentSample = textureSampleBarycoord(
				attributesArray,
				ATTR_TANGENT,
				surfaceHit.barycoord,
				surfaceHit.faceIndices.xyz
			);

			// some provided tangents can be malformed (0, 0, 0) causing the normal to be degenerate
			// resulting in NaNs and slow path tracing.
			if ( length( tangentSample.xyz ) > 0.0 ) {

				vec3 tangent = normalize( tangentSample.xyz );
				vec3 bitangent = normalize( cross( clearcoatNormal, tangent ) * tangentSample.w );
				mat3 vTBN = mat3( tangent, bitangent, clearcoatNormal );

				vec3 uvPrime = material.clearcoatNormalMapTransform * vec3( uv, 1 );
				vec3 texNormal = texture2D( textures, vec3( uvPrime.xy, material.clearcoatNormalMap ) ).xyz * 2.0 - 1.0;
				texNormal.xy *= material.clearcoatNormalScale;
				clearcoatNormal = vTBN * texNormal;

			}

		}

		clearcoatNormal *= surfaceHit.side;

		// sheenColor
		vec3 sheenColor = material.sheenColor;
		if ( material.sheenColorMap != - 1 ) {

			vec3 uvPrime = material.sheenColorMapTransform * vec3( uv, 1 );
			sheenColor *= texture2D( textures, vec3( uvPrime.xy, material.sheenColorMap ) ).rgb;

		}

		// sheenRoughness
		float sheenRoughness = material.sheenRoughness;
		if ( material.sheenRoughnessMap != - 1 ) {

			vec3 uvPrime = material.sheenRoughnessMapTransform * vec3( uv, 1 );
			sheenRoughness *= texture2D( textures, vec3( uvPrime.xy, material.sheenRoughnessMap ) ).a;

		}

		// iridescence
		float iridescence = material.iridescence;
		if ( material.iridescenceMap != - 1 ) {

			vec3 uvPrime = material.iridescenceMapTransform * vec3( uv, 1 );
			iridescence *= texture2D( textures, vec3( uvPrime.xy, material.iridescenceMap ) ).r;

		}

		// iridescence thickness
		float iridescenceThickness = material.iridescenceThicknessMaximum;
		if ( material.iridescenceThicknessMap != - 1 ) {

			vec3 uvPrime = material.iridescenceThicknessMapTransform * vec3( uv, 1 );
			float iridescenceThicknessSampled = texture2D( textures, vec3( uvPrime.xy, material.iridescenceThicknessMap ) ).g;
			iridescenceThickness = mix( material.iridescenceThicknessMinimum, material.iridescenceThicknessMaximum, iridescenceThicknessSampled );

		}

		iridescence = iridescenceThickness == 0.0 ? 0.0 : iridescence;

		// specular color
		vec3 specularColor = material.specularColor;
		if ( material.specularColorMap != - 1 ) {

			vec3 uvPrime = material.specularColorMapTransform * vec3( uv, 1 );
			specularColor *= texture2D( textures, vec3( uvPrime.xy, material.specularColorMap ) ).rgb;

		}

		// specular intensity
		float specularIntensity = material.specularIntensity;
		if ( material.specularIntensityMap != - 1 ) {

			vec3 uvPrime = material.specularIntensityMapTransform * vec3( uv, 1 );
			specularIntensity *= texture2D( textures, vec3( uvPrime.xy, material.specularIntensityMap ) ).a;

		}

		surf.volumeParticle = false;

		surf.faceNormal = surfaceHit.faceNormal;
		surf.normal = normal;

		surf.metalness = metalness;
		surf.color = albedo.rgb;
		surf.emission = emission;

		surf.ior = material.ior;
		surf.transmission = transmission;
		surf.thinFilm = material.thinFilm;
		surf.attenuationColor = material.attenuationColor;
		surf.attenuationDistance = material.attenuationDistance;

		surf.clearcoatNormal = clearcoatNormal;
		surf.clearcoat = clearcoat;

		surf.sheen = material.sheen;
		surf.sheenColor = sheenColor;

		surf.iridescence = iridescence;
		surf.iridescenceIor = material.iridescenceIor;
		surf.iridescenceThickness = iridescenceThickness;

		surf.specularColor = specularColor;
		surf.specularIntensity = specularIntensity;

		// apply perceptual roughness factor from gltf. sheen perceptual roughness is
		// applied by its brdf function
		// https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#microfacet-surfaces
		surf.roughness = roughness * roughness;
		surf.clearcoatRoughness = clearcoatRoughness * clearcoatRoughness;
		surf.sheenRoughness = sheenRoughness;

		// frontFace is used to determine transmissive properties and PDF. If no transmission is used
		// then we can just always assume this is a front face.
		surf.frontFace = surfaceHit.side == 1.0 || transmission == 0.0;
		surf.eta = material.thinFilm || surf.frontFace ? 1.0 / material.ior : material.ior;
		surf.f0 = iorRatioToF0( surf.eta );

		// Compute the filtered roughness value to use during specular reflection computations.
		// The accumulated roughness value is scaled by a user setting and a "magic value" of 5.0.
		// If we're exiting something transmissive then scale the factor down significantly so we can retain
		// sharp internal reflections
		surf.filteredRoughness = applyFilteredGlossy( surf.roughness, accumulatedRoughness );
		surf.filteredClearcoatRoughness = applyFilteredGlossy( surf.clearcoatRoughness, accumulatedRoughness );

		// get the normal frames
		surf.normalBasis = getBasisFromNormal( surf.normal );
		surf.normalInvBasis = inverse( surf.normalBasis );

		surf.clearcoatBasis = getBasisFromNormal( surf.clearcoatNormal );
		surf.clearcoatInvBasis = inverse( surf.clearcoatBasis );

		return HIT_SURFACE;

	}
`;var cm=`

	struct Ray {

		vec3 origin;
		vec3 direction;

	};

	struct SurfaceHit {

		uvec4 faceIndices;
		vec3 barycoord;
		vec3 faceNormal;
		float side;
		float dist;

	};

	struct RenderState {

		bool firstRay;
		bool transmissiveRay;
		bool isShadowRay;
		float accumulatedRoughness;
		int transmissiveTraversals;
		int traversals;
		uint depth;
		vec3 throughputColor;
		Material fogMaterial;

	};

	RenderState initRenderState() {

		RenderState result;
		result.firstRay = true;
		result.transmissiveRay = true;
		result.isShadowRay = false;
		result.accumulatedRoughness = 0.0;
		result.transmissiveTraversals = 0;
		result.traversals = 0;
		result.throughputColor = vec3( 1.0 );
		result.depth = 0u;
		result.fogMaterial.fogVolume = false;
		return result;

	}

`;var lm=`

	#define NO_HIT 0
	#define SURFACE_HIT 1
	#define LIGHT_HIT 2
	#define FOG_HIT 3

	// Passing the global variable 'lights' into this function caused shader program errors.
	// So global variables like 'lights' and 'bvh' were moved out of the function parameters.
	// For more information, refer to: https://github.com/gkjohnson/three-gpu-pathtracer/pull/457
	int traceScene(
		Ray ray, Material fogMaterial, inout SurfaceHit surfaceHit
	) {

		int result = NO_HIT;
		bool hit = bvhIntersectFirstHit( bvh, ray.origin, ray.direction, surfaceHit.faceIndices, surfaceHit.faceNormal, surfaceHit.barycoord, surfaceHit.side, surfaceHit.dist );

		#if FEATURE_FOG

		if ( fogMaterial.fogVolume ) {

			// offset the distance so we don't run into issues with particles on the same surface
			// as other objects
			float particleDist = intersectFogVolume( fogMaterial, rand( 1 ) );
			if ( particleDist + RAY_OFFSET < surfaceHit.dist ) {

				surfaceHit.side = 1.0;
				surfaceHit.faceNormal = normalize( - ray.direction );
				surfaceHit.dist = particleDist;
				return FOG_HIT;

			}

		}

		#endif

		if ( hit ) {

			result = SURFACE_HIT;

		}

		return result;

	}

`;var _l=class extends qi{onBeforeRender(){this.setDefine("FEATURE_DOF",this.physicalCamera.bokehSize===0?0:1),this.setDefine("FEATURE_BACKGROUND_MAP",this.backgroundMap?1:0),this.setDefine("FEATURE_FOG",this.materials.features.isUsed("FOG")?1:0)}constructor(e){super({transparent:!0,depthWrite:!1,defines:{FEATURE_MIS:1,FEATURE_RUSSIAN_ROULETTE:1,FEATURE_DOF:1,FEATURE_BACKGROUND_MAP:0,FEATURE_FOG:1,RANDOM_TYPE:2,CAMERA_TYPE:0,DEBUG_MODE:0,ATTR_NORMAL:0,ATTR_TANGENT:1,ATTR_UV:2,ATTR_COLOR:3,MATERIAL_PIXELS:fl},uniforms:{resolution:{value:new Le},opacity:{value:1},bounces:{value:10},transmissiveBounces:{value:10},filterGlossyFactor:{value:0},physicalCamera:{value:new rl},cameraWorldMatrix:{value:new Xe},invProjectionMatrix:{value:new Xe},bvh:{value:new Gc},attributesArray:{value:new ll},materialIndexAttribute:{value:new ps},materials:{value:new hl},textures:{value:new Ta().texture},lights:{value:new ol},iesProfiles:{value:new Ta(360,180,{type:_t,wrapS:Lt,wrapT:Lt}).texture},environmentIntensity:{value:1},environmentRotation:{value:new Xe},envMapInfo:{value:new al},backgroundBlur:{value:0},backgroundMap:{value:null},backgroundAlpha:{value:1},backgroundIntensity:{value:1},backgroundRotation:{value:new Xe},seed:{value:0},sobolTexture:{value:null},stratifiedTexture:{value:new ml},stratifiedOffsetTexture:{value:new xl(64,1)}},vertexShader:`

				varying vec2 vUv;
				void main() {

					vec4 mvPosition = vec4( position, 1.0 );
					mvPosition = modelViewMatrix * mvPosition;
					gl_Position = projectionMatrix * mvPosition;

					vUv = uv;

				}

			`,fragmentShader:`
				#define RAY_OFFSET 1e-4
				#define INFINITY 1e20

				precision highp isampler2D;
				precision highp usampler2D;
				precision highp sampler2DArray;
				vec4 envMapTexelToLinear( vec4 a ) { return a; }
				#include <common>

				// bvh intersection
				${mr.common_functions}
				${mr.bvh_struct_definitions}
				${mr.bvh_ray_functions}

				// uniform structs
				${zp}
				${Vp}
				${kp}
				${Hp}
				${Gp}

				// random
				#if RANDOM_TYPE == 2 	// Stratified List

					${Kp}

				#elif RANDOM_TYPE == 1 	// Sobol

					${Ih}
					${tl}
					${Ep}

					#define rand(v) sobol(v)
					#define rand2(v) sobol2(v)
					#define rand3(v) sobol3(v)
					#define rand4(v) sobol4(v)

				#else 					// PCG

				${Ih}

					// Using the sobol functions seems to break the the compiler on MacOS
					// - specifically the "sobolReverseBits" function.
					uint sobolPixelIndex = 0u;
					uint sobolPathIndex = 0u;
					uint sobolBounceIndex = 0u;

					#define rand(v) pcgRand()
					#define rand2(v) pcgRand2()
					#define rand3(v) pcgRand3()
					#define rand4(v) pcgRand4()

				#endif

				// common
				${Jp}
				${Yp}
				${vl}
				${Zp}
				${$p}

				// environment
				uniform EquirectHdrInfo envMapInfo;
				uniform mat4 environmentRotation;
				uniform float environmentIntensity;

				// lighting
				uniform sampler2DArray iesProfiles;
				uniform LightsInfo lights;

				// background
				uniform float backgroundBlur;
				uniform float backgroundAlpha;
				#if FEATURE_BACKGROUND_MAP

				uniform sampler2D backgroundMap;
				uniform mat4 backgroundRotation;
				uniform float backgroundIntensity;

				#endif

				// camera
				uniform mat4 cameraWorldMatrix;
				uniform mat4 invProjectionMatrix;
				#if FEATURE_DOF

				uniform PhysicalCamera physicalCamera;

				#endif

				// geometry
				uniform sampler2DArray attributesArray;
				uniform usampler2D materialIndexAttribute;
				uniform sampler2D materials;
				uniform sampler2DArray textures;
				uniform BVH bvh;

				// path tracer
				uniform int bounces;
				uniform int transmissiveBounces;
				uniform float filterGlossyFactor;
				uniform int seed;

				// image
				uniform vec2 resolution;
				uniform float opacity;

				varying vec2 vUv;

				// globals
				mat3 envRotation3x3;
				mat3 invEnvRotation3x3;
				float lightsDenom;

				// sampling
				${qp}
				${Wp}
				${Xp}

				${im}
				${em}
				${nm}
				${tm}
				${jp}
				${Qp}

				float applyFilteredGlossy( float roughness, float accumulatedRoughness ) {

					return clamp(
						max(
							roughness,
							accumulatedRoughness * filterGlossyFactor * 5.0 ),
						0.0,
						1.0
					);

				}

				vec3 sampleBackground( vec3 direction, vec2 uv ) {

					vec3 sampleDir = sampleHemisphere( direction, uv ) * 0.5 * backgroundBlur;

					#if FEATURE_BACKGROUND_MAP

					sampleDir = normalize( mat3( backgroundRotation ) * direction + sampleDir );
					return backgroundIntensity * sampleEquirectColor( backgroundMap, sampleDir );

					#else

					sampleDir = normalize( envRotation3x3 * direction + sampleDir );
					return environmentIntensity * sampleEquirectColor( envMapInfo.map, sampleDir );

					#endif

				}

				${cm}
				${sm}
				${lm}
				${rm}
				${am}
				${om}

				void main() {

					// init
					rng_initialize( gl_FragCoord.xy, seed );
					sobolPixelIndex = ( uint( gl_FragCoord.x ) << 16 ) | uint( gl_FragCoord.y );
					sobolPathIndex = uint( seed );

					// get camera ray
					Ray ray = getCameraRay();

					// inverse environment rotation
					envRotation3x3 = mat3( environmentRotation );
					invEnvRotation3x3 = inverse( envRotation3x3 );
					lightsDenom =
						( environmentIntensity == 0.0 || envMapInfo.totalSum == 0.0 ) && lights.count != 0u ?
							float( lights.count ) :
							float( lights.count + 1u );

					// final color
					gl_FragColor = vec4( 0, 0, 0, 1 );

					// surface results
					SurfaceHit surfaceHit;
					ScatterRecord scatterRec;

					// path tracing state
					RenderState state = initRenderState();
					state.transmissiveTraversals = transmissiveBounces;
					#if FEATURE_FOG

					state.fogMaterial.fogVolume = bvhIntersectFogVolumeHit(
						ray.origin, - ray.direction,
						materialIndexAttribute, materials,
						state.fogMaterial
					);

					#endif

					for ( int i = 0; i < bounces; i ++ ) {

						sobolBounceIndex ++;

						state.depth ++;
						state.traversals = bounces - i;
						state.firstRay = i == 0 && state.transmissiveTraversals == transmissiveBounces;

						int hitType = traceScene( ray, state.fogMaterial, surfaceHit );

						// check if we intersect any lights and accumulate the light contribution
						// TODO: we can add support for light surface rendering in the else condition if we
						// add the ability to toggle visibility of the the light
						if ( ! state.firstRay && ! state.transmissiveRay ) {

							LightRecord lightRec;
							float lightDist = hitType == NO_HIT ? INFINITY : surfaceHit.dist;
							for ( uint i = 0u; i < lights.count; i ++ ) {

								if (
									intersectLightAtIndex( lights.tex, ray.origin, ray.direction, i, lightRec ) &&
									lightRec.dist < lightDist
								) {

									#if FEATURE_MIS

									// weight the contribution
									// NOTE: Only area lights are supported for forward sampling and can be hit
									float misWeight = misHeuristic( scatterRec.pdf, lightRec.pdf / lightsDenom );
									gl_FragColor.rgb += lightRec.emission * state.throughputColor * misWeight;

									#else

									gl_FragColor.rgb += lightRec.emission * state.throughputColor;

									#endif

								}

							}

						}

						if ( hitType == NO_HIT ) {

							if ( state.firstRay || state.transmissiveRay ) {

								gl_FragColor.rgb += sampleBackground( ray.direction, rand2( 2 ) ) * state.throughputColor;
								gl_FragColor.a = backgroundAlpha;

							} else {

								#if FEATURE_MIS

								// get the PDF of the hit envmap point
								vec3 envColor;
								float envPdf = sampleEquirect( envRotation3x3 * ray.direction, envColor );
								envPdf /= lightsDenom;

								// and weight the contribution
								float misWeight = misHeuristic( scatterRec.pdf, envPdf );
								gl_FragColor.rgb += environmentIntensity * envColor * state.throughputColor * misWeight;

								#else

								gl_FragColor.rgb +=
									environmentIntensity *
									sampleEquirectColor( envMapInfo.map, envRotation3x3 * ray.direction ) *
									state.throughputColor;

								#endif

							}
							break;

						}

						uint materialIndex = uTexelFetch1D( materialIndexAttribute, surfaceHit.faceIndices.x ).r;
						Material material = readMaterialInfo( materials, materialIndex );

						#if FEATURE_FOG

						if ( hitType == FOG_HIT ) {

							material = state.fogMaterial;
							state.accumulatedRoughness += 0.2;

						} else if ( material.fogVolume ) {

							state.fogMaterial = material;
							state.fogMaterial.fogVolume = surfaceHit.side == 1.0;

							ray.origin = stepRayOrigin( ray.origin, ray.direction, - surfaceHit.faceNormal, surfaceHit.dist );

							i -= sign( state.transmissiveTraversals );
							state.transmissiveTraversals -= sign( state.transmissiveTraversals );
							continue;

						}

						#endif

						// early out if this is a matte material
						if ( material.matte && state.firstRay ) {

							gl_FragColor = vec4( 0.0 );
							break;

						}

						// if we've determined that this is a shadow ray and we've hit an item with no shadow casting
						// then skip it
						if ( ! material.castShadow && state.isShadowRay ) {

							ray.origin = stepRayOrigin( ray.origin, ray.direction, - surfaceHit.faceNormal, surfaceHit.dist );
							continue;

						}

						SurfaceRecord surf;
						if (
							getSurfaceRecord(
								material, surfaceHit, attributesArray, state.accumulatedRoughness,
								surf
							) == SKIP_SURFACE
						) {

							// only allow a limited number of transparency discards otherwise we could
							// crash the context with too long a loop.
							i -= sign( state.transmissiveTraversals );
							state.transmissiveTraversals -= sign( state.transmissiveTraversals );

							ray.origin = stepRayOrigin( ray.origin, ray.direction, - surfaceHit.faceNormal, surfaceHit.dist );
							continue;

						}

						scatterRec = bsdfSample( - ray.direction, surf );
						state.isShadowRay = scatterRec.specularPdf < rand( 4 );

						bool isBelowSurface = ! surf.volumeParticle && dot( scatterRec.direction, surf.faceNormal ) < 0.0;
						vec3 hitPoint = stepRayOrigin( ray.origin, ray.direction, isBelowSurface ? - surf.faceNormal : surf.faceNormal, surfaceHit.dist );

						// next event estimation
						#if FEATURE_MIS

						gl_FragColor.rgb += directLightContribution( - ray.direction, surf, state, hitPoint );

						#endif

						// accumulate a roughness value to offset diffuse, specular, diffuse rays that have high contribution
						// to a single pixel resulting in fireflies
						// TODO: handle transmissive surfaces
						if ( ! surf.volumeParticle && ! isBelowSurface ) {

							// determine if this is a rough normal or not by checking how far off straight up it is
							vec3 halfVector = normalize( - ray.direction + scatterRec.direction );
							state.accumulatedRoughness += max(
								sin( acosApprox( dot( halfVector, surf.normal ) ) ),
								sin( acosApprox( dot( halfVector, surf.clearcoatNormal ) ) )
							);

							state.transmissiveRay = false;

						}

						// accumulate emissive color
						gl_FragColor.rgb += ( surf.emission * state.throughputColor );

						// skip the sample if our PDF or ray is impossible
						if ( scatterRec.pdf <= 0.0 || ! isDirectionValid( scatterRec.direction, surf.normal, surf.faceNormal ) ) {

							break;

						}

						// if we're bouncing around the inside a transmissive material then decrement
						// perform this separate from a bounce
						bool isTransmissiveRay = ! surf.volumeParticle && dot( scatterRec.direction, surf.faceNormal * surfaceHit.side ) < 0.0;
						if ( ( isTransmissiveRay || isBelowSurface ) && state.transmissiveTraversals > 0 ) {

							state.transmissiveTraversals --;
							i --;

						}

						//

						// handle throughput color transformation
						// attenuate the throughput color by the medium color
						if ( ! surf.frontFace ) {

							state.throughputColor *= transmissionAttenuation( surfaceHit.dist, surf.attenuationColor, surf.attenuationDistance );

						}

						#if FEATURE_RUSSIAN_ROULETTE

						// russian roulette path termination
						// https://www.arnoldrenderer.com/research/physically_based_shader_design_in_arnold.pdf
						uint minBounces = 3u;
						float depthProb = float( state.depth < minBounces );

						float rrProb = luminance( state.throughputColor * scatterRec.color / scatterRec.pdf );
						rrProb /= luminance( state.throughputColor );
						rrProb = sqrt( rrProb );
						rrProb = max( rrProb, depthProb );
						rrProb = min( rrProb, 1.0 );
						if ( rand( 8 ) > rrProb ) {

							break;

						}

						// perform sample clamping here to avoid bright pixels
						state.throughputColor *= min( 1.0 / rrProb, 20.0 );

						#endif

						// adjust the throughput and discard and exit if we find discard the sample if there are any NaNs
						state.throughputColor *= scatterRec.color / scatterRec.pdf;
						if ( any( isnan( state.throughputColor ) ) || any( isinf( state.throughputColor ) ) ) {

							break;

						}

						//

						// prepare for next ray
						ray.direction = scatterRec.direction;
						ray.origin = hitPoint;

					}

					gl_FragColor.a *= opacity;

					#if DEBUG_MODE == 1

					// output the number of rays checked in the path and number of
					// transmissive rays encountered.
					gl_FragColor.rgb = vec3(
						float( state.depth ),
						transmissiveBounces - state.transmissiveTraversals,
						0.0
					);
					gl_FragColor.a = 1.0;

					#endif

				}

			`}),this.setValues(e)}};function*Gy(){let{_renderer:i,_fsQuad:e,_blendQuad:t,_primaryTarget:n,_blendTargets:r,_sobolTarget:s,_subframe:a,alpha:o,material:c}=this,u=new ht,f=new ht,h=t.material,[l,p]=r;for(;;){o?(h.opacity=this._opacityFactor/(this.samples+1),c.blending=$t,c.opacity=1):(c.opacity=this._opacityFactor/(this.samples+1),c.blending=Gn);let[g,b,m,d]=a,_=n.width,y=n.height;c.resolution.set(_*m,y*d),c.sobolTexture=s.texture,c.stratifiedTexture.init(20,c.bounces+c.transmissiveBounces+5),c.stratifiedTexture.next(),c.seed++;let M=this.tiles.x||1,w=this.tiles.y||1,A=M*w,I=Math.ceil(_*m),D=Math.ceil(y*d),T=Math.floor(g*_),S=Math.floor(b*y),P=Math.ceil(I/M),L=Math.ceil(D/w);for(let O=0;O<w;O++)for(let H=0;H<M;H++){let q=i.getRenderTarget(),Y=i.autoClear,he=i.getScissorTest();i.getScissor(u),i.getViewport(f);let j=H,le=O;if(!this.stableTiles){let we=this._currentTile%(M*w);j=we%M,le=~~(we/M),this._currentTile=we+1}let ce=w-le-1;n.scissor.set(T+j*P,S+ce*L,Math.min(P,I-j*P),Math.min(L,D-ce*L)),n.viewport.set(T,S,I,D),i.setRenderTarget(n),i.setScissorTest(!0),i.autoClear=!1,e.render(i),i.setViewport(f),i.setScissor(u),i.setScissorTest(he),i.setRenderTarget(q),i.autoClear=Y,o&&(h.target1=l.texture,h.target2=n.texture,i.setRenderTarget(p),t.render(i),i.setRenderTarget(q)),this.samples+=1/A,H===M-1&&O===w-1&&(this.samples=Math.round(this.samples)),yield}[l,p]=[p,l]}}var um=new Ye,Aa=class{get material(){return this._fsQuad.material}set material(e){this._fsQuad.material.removeEventListener("recompilation",this._compileFunction),e.addEventListener("recompilation",this._compileFunction),this._fsQuad.material=e}get target(){return this._alpha?this._blendTargets[1]:this._primaryTarget}set alpha(e){this._alpha!==e&&(e||(this._blendTargets[0].dispose(),this._blendTargets[1].dispose()),this._alpha=e,this.reset())}get alpha(){return this._alpha}get isCompiling(){return!!this._compilePromise}constructor(e){this.camera=null,this.tiles=new Le(3,3),this.stableNoise=!1,this.stableTiles=!0,this.samples=0,this._subframe=new ht(0,0,1,1),this._opacityFactor=1,this._renderer=e,this._alpha=!1,this._fsQuad=new Pn(new _l),this._blendQuad=new Pn(new Qc),this._task=null,this._currentTile=0,this._compilePromise=null,this._sobolTarget=new nl().generate(e),this._primaryTarget=new Yt(1,1,{format:He,type:qe,magFilter:je,minFilter:je}),this._blendTargets=[new Yt(1,1,{format:He,type:qe,magFilter:je,minFilter:je}),new Yt(1,1,{format:He,type:qe,magFilter:je,minFilter:je})],this._compileFunction=()=>{let t=this.compileMaterial(this._fsQuad._mesh);t.then(()=>{this._compilePromise===t&&(this._compilePromise=null)}),this._compilePromise=t},this.material.addEventListener("recompilation",this._compileFunction)}compileMaterial(){return this._renderer.compileAsync(this._fsQuad._mesh)}setCamera(e){let{material:t}=this;t.cameraWorldMatrix.copy(e.matrixWorld),t.invProjectionMatrix.copy(e.projectionMatrixInverse),t.physicalCamera.updateFrom(e);let n=0;e.projectionMatrix.elements[15]>0&&(n=1),e.isEquirectCamera&&(n=2),t.setDefine("CAMERA_TYPE",n),this.camera=e}setSize(e,t){e=Math.ceil(e),t=Math.ceil(t),!(this._primaryTarget.width===e&&this._primaryTarget.height===t)&&(this._primaryTarget.setSize(e,t),this._blendTargets[0].setSize(e,t),this._blendTargets[1].setSize(e,t),this.reset())}getSize(e){e.x=this._primaryTarget.width,e.y=this._primaryTarget.height}dispose(){this._primaryTarget.dispose(),this._blendTargets[0].dispose(),this._blendTargets[1].dispose(),this._sobolTarget.dispose(),this._fsQuad.dispose(),this._blendQuad.dispose(),this._task=null}reset(){let{_renderer:e,_primaryTarget:t,_blendTargets:n}=this,r=e.getRenderTarget(),s=e.getClearAlpha();e.getClearColor(um),e.setRenderTarget(t),e.setClearColor(0,0),e.clearColor(),e.setRenderTarget(n[0]),e.setClearColor(0,0),e.clearColor(),e.setRenderTarget(n[1]),e.setClearColor(0,0),e.clearColor(),e.setClearColor(um,s),e.setRenderTarget(r),this.samples=0,this._task=null,this.material.stratifiedTexture.stableNoise=this.stableNoise,this.stableNoise&&(this.material.seed=0,this.material.stratifiedTexture.reset())}update(){this.material.onBeforeRender(),!this.isCompiling&&(this._task||(this._task=Gy.call(this)),this._task.next())}};var yr=new Le,hm=new Le,yl=new ea,bl=new Ye,Sl=class extends St{constructor(e=512,t=512){super(new Float32Array(e*t*4),e,t,He,qe,ei,hn,Lt,ft,ft),this.generationCallback=null}update(){this.dispose(),this.needsUpdate=!0;let{data:e,width:t,height:n}=this.image;for(let r=0;r<t;r++)for(let s=0;s<n;s++){hm.set(t,n),yr.set(r/t,s/n),yr.x-=.5,yr.y=1-yr.y,yl.theta=yr.x*2*Math.PI,yl.phi=yr.y*Math.PI,yl.radius=1,this.generationCallback(yl,yr,hm,bl);let o=4*(s*t+r);e[o+0]=bl.r,e[o+1]=bl.g,e[o+2]=bl.b,e[o+3]=1}}copy(e){return super.copy(e),this.generationCallback=e.generationCallback,this}};var fm=new k,Ml=class extends Sl{constructor(e=512){super(e,e),this.topColor=new Ye().set(16777215),this.bottomColor=new Ye().set(0),this.exponent=2,this.generationCallback=(t,n,r,s)=>{fm.setFromSpherical(t);let a=fm.y*.5+.5;s.lerpColors(this.bottomColor,this.topColor,a**this.exponent)}}copy(e){return super.copy(e),this.topColor.copy(e.topColor),this.bottomColor.copy(e.bottomColor),this}};var Tl=class extends Xt{get map(){return this.uniforms.map.value}set map(e){this.uniforms.map.value=e}get opacity(){return this.uniforms.opacity.value}set opacity(e){this.uniforms&&(this.uniforms.opacity.value=e)}constructor(e){super({uniforms:{map:{value:null},opacity:{value:1}},vertexShader:`
				varying vec2 vUv;
				void main() {

					vUv = uv;
					gl_Position = projectionMatrix * modelViewMatrix * vec4( position, 1.0 );

				}
			`,fragmentShader:`
				uniform sampler2D map;
				uniform float opacity;
				varying vec2 vUv;

				vec4 clampedTexelFatch( sampler2D map, ivec2 px, int lod ) {

					vec4 res = texelFetch( map, ivec2( px.x, px.y ), 0 );

					#if defined( TONE_MAPPING )

					res.xyz = toneMapping( res.xyz );

					#endif

			  		return linearToOutputTexel( res );

				}

				void main() {

					vec2 size = vec2( textureSize( map, 0 ) );
					vec2 pxUv = vUv * size;
					vec2 pxCurr = floor( pxUv );
					vec2 pxFrac = fract( pxUv ) - 0.5;
					vec2 pxOffset;
					pxOffset.x = pxFrac.x > 0.0 ? 1.0 : - 1.0;
					pxOffset.y = pxFrac.y > 0.0 ? 1.0 : - 1.0;

					vec2 pxNext = clamp( pxOffset + pxCurr, vec2( 0.0 ), size - 1.0 );
					vec2 alpha = abs( pxFrac );

					vec4 p1 = mix(
						clampedTexelFatch( map, ivec2( pxCurr.x, pxCurr.y ), 0 ),
						clampedTexelFatch( map, ivec2( pxNext.x, pxCurr.y ), 0 ),
						alpha.x
					);

					vec4 p2 = mix(
						clampedTexelFatch( map, ivec2( pxCurr.x, pxNext.y ), 0 ),
						clampedTexelFatch( map, ivec2( pxNext.x, pxNext.y ), 0 ),
						alpha.x
					);

					gl_FragColor = mix( p1, p2, alpha.y );
					gl_FragColor.a *= opacity;
					#include <premultiplied_alpha_fragment>

				}
			`}),this.setValues(e)}};var Ph=class extends Xt{constructor(){super({uniforms:{envMap:{value:null},flipEnvMap:{value:-1}},vertexShader:`
				varying vec2 vUv;
				void main() {

					vUv = uv;
					gl_Position = projectionMatrix * modelViewMatrix * vec4( position, 1.0 );

				}`,fragmentShader:`
				#define ENVMAP_TYPE_CUBE_UV

				uniform samplerCube envMap;
				uniform float flipEnvMap;
				varying vec2 vUv;

				#include <common>
				#include <cube_uv_reflection_fragment>

				${vl}

				void main() {

					vec3 rayDirection = equirectUvToDirection( vUv );
					rayDirection.x *= flipEnvMap;
					gl_FragColor = textureCube( envMap, rayDirection );

				}`}),this.depthWrite=!1,this.depthTest=!1}},Ea=class{constructor(e){this._renderer=e,this._quad=new Pn(new Ph)}generate(e,t=null,n=null){if(!e.isCubeTexture)throw new Error("CubeToEquirectMaterial: Source can only be cube textures.");let r=e.images[0],s=this._renderer,a=this._quad;t===null&&(t=4*r.height),n===null&&(n=2*r.height);let o=new Yt(t,n,{type:qe,colorSpace:r.colorSpace}),c=r.height,u=Math.log2(c)-2,f=1/c,h=1/(3*Math.max(Math.pow(2,u),112));a.material.defines.CUBEUV_MAX_MIP=`${u}.0`,a.material.defines.CUBEUV_TEXEL_WIDTH=h,a.material.defines.CUBEUV_TEXEL_HEIGHT=f,a.material.uniforms.envMap.value=e,a.material.uniforms.flipEnvMap.value=e.isRenderTargetTexture?1:-1,a.material.needsUpdate=!0;let l=s.getRenderTarget(),p=s.autoClear;s.autoClear=!0,s.setRenderTarget(o),a.render(s),s.setRenderTarget(l),s.autoClear=p;let g=new Uint16Array(t*n*4),b=new Float32Array(t*n*4);s.readRenderTargetPixels(o,0,0,t,n,b),o.dispose();for(let d=0,_=b.length;d<_;d++)g[d]=Ot.toHalfFloat(b[d]);let m=new St(g,t,n,He,_t);return m.minFilter=Su,m.magFilter=ft,m.wrapS=hn,m.wrapT=hn,m.mapping=ei,m.needsUpdate=!0,m}dispose(){this._quad.dispose()}};function Wy(i){return i.extensions.get("EXT_float_blend")}var _s=new Le,wl=class{get multipleImportanceSampling(){return!!this._pathTracer.material.defines.FEATURE_MIS}set multipleImportanceSampling(e){this._pathTracer.material.setDefine("FEATURE_MIS",e?1:0)}get transmissiveBounces(){return this._pathTracer.material.transmissiveBounces}set transmissiveBounces(e){this._pathTracer.material.transmissiveBounces=e}get bounces(){return this._pathTracer.material.bounces}set bounces(e){this._pathTracer.material.bounces=e}get filterGlossyFactor(){return this._pathTracer.material.filterGlossyFactor}set filterGlossyFactor(e){this._pathTracer.material.filterGlossyFactor=e}get samples(){return this._pathTracer.samples}get target(){return this._pathTracer.target}get tiles(){return this._pathTracer.tiles}get stableNoise(){return this._pathTracer.stableNoise}set stableNoise(e){this._pathTracer.stableNoise=e}get isCompiling(){return!!this._pathTracer.isCompiling}constructor(e){this._renderer=e,this._generator=new Kc,this._pathTracer=new Aa(e),this._queueReset=!1,this._clock=new js,this._compilePromise=null,this._lowResPathTracer=new Aa(e),this._lowResPathTracer.tiles.set(1,1),this._quad=new Pn(new Tl({map:null,transparent:!0,blending:$t,premultipliedAlpha:e.getContextAttributes().premultipliedAlpha})),this._materials=null,this._previousEnvironment=null,this._previousBackground=null,this._internalBackground=null,this.renderDelay=100,this.minSamples=5,this.fadeDuration=500,this.enablePathTracing=!0,this.pausePathTracing=!1,this.dynamicLowRes=!1,this.lowResScale=.25,this.renderScale=1,this.synchronizeRenderSize=!0,this.rasterizeScene=!0,this.renderToCanvas=!0,this.textureSize=new Le(1024,1024),this.rasterizeSceneCallback=(t,n)=>{this._renderer.render(t,n)},this.renderToCanvasCallback=(t,n,r)=>{let s=n.autoClear;n.autoClear=!1,r.render(n),n.autoClear=s},this.setScene(new ir,new kt)}setBVHWorker(e){this._generator.setBVHWorker(e)}setScene(e,t,n={}){e.updateMatrixWorld(!0),t.updateMatrixWorld();let r=this._generator;if(r.setObjects(e),this._buildAsync)return r.generateAsync(n.onProgress).then(s=>this._updateFromResults(e,t,s));{let s=r.generate();return this._updateFromResults(e,t,s)}}setSceneAsync(...e){this._buildAsync=!0;let t=this.setScene(...e);return this._buildAsync=!1,t}setCamera(e){this.camera=e,this.updateCamera()}updateCamera(){let e=this.camera;e.updateMatrixWorld(),this._pathTracer.setCamera(e),this._lowResPathTracer.setCamera(e),this.reset()}updateMaterials(){let e=this._pathTracer.material,t=this._renderer,n=this._materials,r=this.textureSize,s=Fp(n);e.textures.setTextures(t,s,r.x,r.y),e.materials.updateFrom(n,s),this.reset()}updateLights(){let e=this.scene,t=this._renderer,n=this._pathTracer.material,r=Lp(e),s=Dp(r);n.lights.updateFrom(r,s),n.iesProfiles.setTextures(t,s),this.reset()}updateEnvironment(){let e=this.scene,t=this._pathTracer.material;if(this._internalBackground&&(this._internalBackground.dispose(),this._internalBackground=null),t.backgroundBlur=e.backgroundBlurriness,t.backgroundIntensity=e.backgroundIntensity??1,t.backgroundRotation.makeRotationFromEuler(e.backgroundRotation).invert(),e.background===null)t.backgroundMap=null,t.backgroundAlpha=0;else if(e.background.isColor){this._colorBackground=this._colorBackground||new Ml(16);let n=this._colorBackground;n.topColor.equals(e.background)||(n.topColor.set(e.background),n.bottomColor.set(e.background),n.update()),t.backgroundMap=n,t.backgroundAlpha=1}else if(e.background.isCubeTexture){if(e.background!==this._previousBackground){let n=new Ea(this._renderer).generate(e.background);this._internalBackground=n,t.backgroundMap=n,t.backgroundAlpha=1}}else t.backgroundMap=e.background,t.backgroundAlpha=1;if(t.environmentIntensity=e.environment!==null?e.environmentIntensity??1:0,t.environmentRotation.makeRotationFromEuler(e.environmentRotation).invert(),this._previousEnvironment!==e.environment&&e.environment!==null)if(e.environment.isCubeTexture){let n=new Ea(this._renderer).generate(e.environment);t.envMapInfo.updateFrom(n)}else t.envMapInfo.updateFrom(e.environment);this._previousEnvironment=e.environment,this._previousBackground=e.background,this.reset()}_updateFromResults(e,t,n){let{materials:r,geometry:s,bvh:a,bvhChanged:o,needsMaterialIndexUpdate:c}=n;this._materials=r;let f=this._pathTracer.material;return o&&(f.bvh.updateFrom(a),f.attributesArray.updateFrom(s.attributes.normal,s.attributes.tangent,s.attributes.uv,s.attributes.color)),c&&f.materialIndexAttribute.updateFrom(s.attributes.materialIndex),this._previousScene=e,this.scene=e,this.camera=t,this.updateCamera(),this.updateMaterials(),this.updateEnvironment(),this.updateLights(),n}renderSample(){let e=this._lowResPathTracer,t=this._pathTracer,n=this._renderer,r=this._clock,s=this._quad;this._updateScale(),this._queueReset&&(t.reset(),e.reset(),this._queueReset=!1,s.material.opacity=0,r.start());let a=r.getDelta()*1e3,o=r.getElapsedTime()*1e3;if(!this.pausePathTracing&&this.enablePathTracing&&this.renderDelay<=o&&!this.isCompiling&&t.update(),t.alpha=t.material.backgroundAlpha!==1||!Wy(n),e.alpha=t.alpha,this.renderToCanvas){let c=this._renderer,u=this.minSamples;if(o>=this.renderDelay&&this.samples>=this.minSamples&&(this.fadeDuration!==0?s.material.opacity=Math.min(s.material.opacity+a/this.fadeDuration,1):s.material.opacity=1),!this.enablePathTracing||this.samples<u||s.material.opacity<1){if(this.dynamicLowRes&&!this.isCompiling){e.samples<1&&(e.material=t.material,e.update());let f=s.material.opacity;s.material.opacity=1-s.material.opacity,s.material.map=e.target.texture,s.render(c),s.material.opacity=f}(!this.dynamicLowRes&&this.rasterizeScene||this.dynamicLowRes&&this.isCompiling)&&this.rasterizeSceneCallback(this.scene,this.camera)}this.enablePathTracing&&s.material.opacity>0&&(s.material.opacity<1&&(s.material.blending=this.dynamicLowRes?ta:Gn),s.material.map=t.target.texture,this.renderToCanvasCallback(t.target,c,s),s.material.blending=$t)}}reset(){this._queueReset=!0,this._pathTracer.samples=0}dispose(){this._quad.dispose(),this._quad.material.dispose(),this._pathTracer.dispose()}_updateScale(){if(this.synchronizeRenderSize){this._renderer.getDrawingBufferSize(_s);let e=Math.floor(this.renderScale*_s.x),t=Math.floor(this.renderScale*_s.y);if(this._pathTracer.getSize(_s),_s.x!==e||_s.y!==t){let n=this.lowResScale;this._pathTracer.setSize(e,t),this._lowResPathTracer.setSize(Math.floor(e*n),Math.floor(t*n))}}}};var Al=class extends sr{constructor(e){super(e),this.type=_t}parse(e){let a=function(D,T){switch(D){case 1:throw new Error("THREE.HDRLoader: Read Error: "+(T||""));case 2:throw new Error("THREE.HDRLoader: Write Error: "+(T||""));case 3:throw new Error("THREE.HDRLoader: Bad File Format: "+(T||""));default:case 4:throw new Error("THREE.HDRLoader: Memory Error: "+(T||""))}},h=function(D,T,S){T=T||1024;let L=D.pos,O=-1,H=0,q="",Y=String.fromCharCode.apply(null,new Uint16Array(D.subarray(L,L+128)));for(;0>(O=Y.indexOf(`
`))&&H<T&&L<D.byteLength;)q+=Y,H+=Y.length,L+=128,Y+=String.fromCharCode.apply(null,new Uint16Array(D.subarray(L,L+128)));return-1<O?(S!==!1&&(D.pos+=H+O+1),q+Y.slice(0,O)):!1},l=function(D){let T=/^#\?(\S+)/,S=/^\s*GAMMA\s*=\s*(\d+(\.\d+)?)\s*$/,P=/^\s*EXPOSURE\s*=\s*(\d+(\.\d+)?)\s*$/,L=/^\s*FORMAT=(\S+)\s*$/,O=/^\s*\-Y\s+(\d+)\s+\+X\s+(\d+)\s*$/,H={valid:0,string:"",comments:"",programtype:"RGBE",format:"",gamma:1,exposure:1,width:0,height:0},q,Y;for((D.pos>=D.byteLength||!(q=h(D)))&&a(1,"no header found"),(Y=q.match(T))||a(3,"bad initial token"),H.valid|=1,H.programtype=Y[1],H.string+=q+`
`;q=h(D),q!==!1;){if(H.string+=q+`
`,q.charAt(0)==="#"){H.comments+=q+`
`;continue}if((Y=q.match(S))&&(H.gamma=parseFloat(Y[1])),(Y=q.match(P))&&(H.exposure=parseFloat(Y[1])),(Y=q.match(L))&&(H.valid|=2,H.format=Y[1]),(Y=q.match(O))&&(H.valid|=4,H.height=parseInt(Y[1],10),H.width=parseInt(Y[2],10)),H.valid&2&&H.valid&4)break}return H.valid&2||a(3,"missing format specifier"),H.valid&4||a(3,"missing image size specifier"),H},p=function(D,T,S){let P=T;if(P<8||P>32767||D[0]!==2||D[1]!==2||D[2]&128)return new Uint8Array(D);P!==(D[2]<<8|D[3])&&a(3,"wrong scanline width");let L=new Uint8Array(4*T*S);L.length||a(4,"unable to allocate buffer space");let O=0,H=0,q=4*P,Y=new Uint8Array(4),he=new Uint8Array(q),j=S;for(;j>0&&H<D.byteLength;){H+4>D.byteLength&&a(1),Y[0]=D[H++],Y[1]=D[H++],Y[2]=D[H++],Y[3]=D[H++],(Y[0]!=2||Y[1]!=2||(Y[2]<<8|Y[3])!=P)&&a(3,"bad rgbe scanline format");let le=0,ce;for(;le<q&&H<D.byteLength;){ce=D[H++];let Ce=ce>128;if(Ce&&(ce-=128),(ce===0||le+ce>q)&&a(3,"bad scanline data"),Ce){let ke=D[H++];for(let ct=0;ct<ce;ct++)he[le++]=ke}else he.set(D.subarray(H,H+ce),le),le+=ce,H+=ce}let we=P;for(let Ce=0;Ce<we;Ce++){let ke=0;L[O]=he[Ce+ke],ke+=P,L[O+1]=he[Ce+ke],ke+=P,L[O+2]=he[Ce+ke],ke+=P,L[O+3]=he[Ce+ke],O+=4}j--}return L},g=function(D,T,S,P){let L=D[T+3],O=Math.pow(2,L-128)/255;S[P+0]=D[T+0]*O,S[P+1]=D[T+1]*O,S[P+2]=D[T+2]*O,S[P+3]=1},b=function(D,T,S,P){let L=D[T+3],O=Math.pow(2,L-128)/255;S[P+0]=Ot.toHalfFloat(Math.min(D[T+0]*O,65504)),S[P+1]=Ot.toHalfFloat(Math.min(D[T+1]*O,65504)),S[P+2]=Ot.toHalfFloat(Math.min(D[T+2]*O,65504)),S[P+3]=Ot.toHalfFloat(1)},m=new Uint8Array(e);m.pos=0;let d=l(m),_=d.width,y=d.height,M=p(m.subarray(m.pos),_,y),w,A,I;switch(this.type){case qe:I=M.length/4;let D=new Float32Array(I*4);for(let S=0;S<I;S++)g(M,S*4,D,S*4);w=D,A=qe;break;case _t:I=M.length/4;let T=new Uint16Array(I*4);for(let S=0;S<I;S++)b(M,S*4,T,S*4);w=T,A=_t;break;default:throw new Error("THREE.HDRLoader: Unsupported type: "+this.type)}return{width:_,height:y,data:w,header:d.string,gamma:d.gamma,exposure:d.exposure,type:A}}setDataType(e){return this.type=e,this}load(e,t,n,r){function s(a,o){switch(a.type){case qe:case _t:a.colorSpace=Gt,a.minFilter=ft,a.magFilter=ft,a.generateMipmaps=!1,a.flipY=!0;break}t&&t(a,o)}return super.load(e,s,n,r)}};var Bn=Uint8Array,ys=Uint16Array,Xy=Int32Array,dm=new Bn([0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0,0,0,0]),pm=new Bn([0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13,0,0]),qy=new Bn([16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15]),mm=function(i,e){for(var t=new ys(31),n=0;n<31;++n)t[n]=e+=1<<i[n-1];for(var r=new Xy(t[30]),n=1;n<30;++n)for(var s=t[n];s<t[n+1];++s)r[s]=s-t[n]<<5|n;return{b:t,r}},gm=mm(dm,2),xm=gm.b,Yy=gm.r;xm[28]=258,Yy[258]=28;var vm=mm(pm,0),Zy=vm.b,W2=vm.r,Lh=new ys(32768);for(xt=0;xt<32768;++xt)yi=(xt&43690)>>1|(xt&21845)<<1,yi=(yi&52428)>>2|(yi&13107)<<2,yi=(yi&61680)>>4|(yi&3855)<<4,Lh[xt]=((yi&65280)>>8|(yi&255)<<8)>>1;var yi,xt,Ca=(function(i,e,t){for(var n=i.length,r=0,s=new ys(e);r<n;++r)i[r]&&++s[i[r]-1];var a=new ys(e);for(r=1;r<e;++r)a[r]=a[r-1]+s[r-1]<<1;var o;if(t){o=new ys(1<<e);var c=15-e;for(r=0;r<n;++r)if(i[r])for(var u=r<<4|i[r],f=e-i[r],h=a[i[r]-1]++<<f,l=h|(1<<f)-1;h<=l;++h)o[Lh[h]>>c]=u}else for(o=new ys(n),r=0;r<n;++r)i[r]&&(o[r]=Lh[a[i[r]-1]++]>>15-i[r]);return o}),Ra=new Bn(288);for(xt=0;xt<144;++xt)Ra[xt]=8;var xt;for(xt=144;xt<256;++xt)Ra[xt]=9;var xt;for(xt=256;xt<280;++xt)Ra[xt]=7;var xt;for(xt=280;xt<288;++xt)Ra[xt]=8;var xt,_m=new Bn(32);for(xt=0;xt<32;++xt)_m[xt]=5;var xt;var $y=Ca(Ra,9,1);var Jy=Ca(_m,5,1),Dh=function(i){for(var e=i[0],t=1;t<i.length;++t)i[t]>e&&(e=i[t]);return e},$n=function(i,e,t){var n=e/8|0;return(i[n]|i[n+1]<<8)>>(e&7)&t},Fh=function(i,e){var t=e/8|0;return(i[t]|i[t+1]<<8|i[t+2]<<16)>>(e&7)},Ky=function(i){return(i+7)/8|0},Qy=function(i,e,t){return(e==null||e<0)&&(e=0),(t==null||t>i.length)&&(t=i.length),new Bn(i.subarray(e,t))};var jy=["unexpected EOF","invalid block type","invalid length/literal","invalid distance","stream finished","no stream handler",,"no callback","invalid UTF-8 data","extra field too long","date not in range 1980-2099","filename too long","stream finishing","invalid zip data"],Jn=function(i,e,t){var n=new Error(e||jy[i]);if(n.code=i,Error.captureStackTrace&&Error.captureStackTrace(n,Jn),!t)throw n;return n},eb=function(i,e,t,n){var r=i.length,s=n?n.length:0;if(!r||e.f&&!e.l)return t||new Bn(0);var a=!t,o=a||e.i!=2,c=e.i;a&&(t=new Bn(r*3));var u=function(Qe){var Rt=t.length;if(Qe>Rt){var tt=new Bn(Math.max(Rt*2,Qe));tt.set(t),t=tt}},f=e.f||0,h=e.p||0,l=e.b||0,p=e.l,g=e.d,b=e.m,m=e.n,d=r*8;do{if(!p){f=$n(i,h,1);var _=$n(i,h+1,3);if(h+=3,_)if(_==1)p=$y,g=Jy,b=9,m=5;else if(_==2){var A=$n(i,h,31)+257,I=$n(i,h+10,15)+4,D=A+$n(i,h+5,31)+1;h+=14;for(var T=new Bn(D),S=new Bn(19),P=0;P<I;++P)S[qy[P]]=$n(i,h+P*3,7);h+=I*3;for(var L=Dh(S),O=(1<<L)-1,H=Ca(S,L,1),P=0;P<D;){var q=H[$n(i,h,O)];h+=q&15;var y=q>>4;if(y<16)T[P++]=y;else{var Y=0,he=0;for(y==16?(he=3+$n(i,h,3),h+=2,Y=T[P-1]):y==17?(he=3+$n(i,h,7),h+=3):y==18&&(he=11+$n(i,h,127),h+=7);he--;)T[P++]=Y}}var j=T.subarray(0,A),le=T.subarray(A);b=Dh(j),m=Dh(le),p=Ca(j,b,1),g=Ca(le,m,1)}else Jn(1);else{var y=Ky(h)+4,M=i[y-4]|i[y-3]<<8,w=y+M;if(w>r){c&&Jn(0);break}o&&u(l+M),t.set(i.subarray(y,w),l),e.b=l+=M,e.p=h=w*8,e.f=f;continue}if(h>d){c&&Jn(0);break}}o&&u(l+131072);for(var ce=(1<<b)-1,we=(1<<m)-1,Ce=h;;Ce=h){var Y=p[Fh(i,h)&ce],ke=Y>>4;if(h+=Y&15,h>d){c&&Jn(0);break}if(Y||Jn(2),ke<256)t[l++]=ke;else if(ke==256){Ce=h,p=null;break}else{var ct=ke-254;if(ke>264){var P=ke-257,nt=dm[P];ct=$n(i,h,(1<<nt)-1)+xm[P],h+=nt}var K=g[Fh(i,h)&we],re=K>>4;K||Jn(3),h+=K&15;var le=Zy[re];if(re>3){var nt=pm[re];le+=Fh(i,h)&(1<<nt)-1,h+=nt}if(h>d){c&&Jn(0);break}o&&u(l+131072);var be=l+ct;if(l<le){var We=s-le,Pe=Math.min(le,be);for(We+l<0&&Jn(3);l<Pe;++l)t[l]=n[We+l]}for(;l<be;++l)t[l]=t[l-le]}}e.l=p,e.p=Ce,e.b=l,e.f=f,p&&(f=1,e.m=b,e.d=g,e.n=m)}while(!f);return l!=t.length&&a?Qy(t,0,l):t.subarray(0,l)};var tb=new Bn(0);var nb=function(i,e){return((i[0]&15)!=8||i[0]>>4>7||(i[0]<<8|i[1])%31)&&Jn(6,"invalid zlib data"),(i[1]>>5&1)==+!e&&Jn(6,"invalid zlib data: "+(i[1]&32?"need":"unexpected")+" dictionary"),(i[1]>>3&4)+2};function Ia(i,e){return eb(i.subarray(nb(i,e&&e.dictionary),-4),{i:2},e&&e.out,e&&e.dictionary)}var ib=typeof TextDecoder<"u"&&new TextDecoder,rb=0;try{ib.decode(tb,{stream:!0}),rb=1}catch{}var El=class extends sr{constructor(e){super(e),this.type=_t,this.outputFormat=He}parse(e){let T=Math.pow(2.7182818,2.2);function S(x,C){let B=0;for(let F=0;F<65536;++F)(F==0||x[F>>3]&1<<(F&7))&&(C[B++]=F);let v=B-1;for(;B<65536;)C[B++]=0;return v}function P(x){for(let C=0;C<16384;C++)x[C]={},x[C].len=0,x[C].lit=0,x[C].p=null}let L={l:0,c:0,lc:0};function O(x,C,B,v,F){for(;B<x;)C=C<<8|ze(v,F),B+=8;B-=x,L.l=C>>B&(1<<x)-1,L.c=C,L.lc=B}let H=new Array(59);function q(x){for(let B=0;B<=58;++B)H[B]=0;for(let B=0;B<65537;++B)H[x[B]]+=1;let C=0;for(let B=58;B>0;--B){let v=C+H[B]>>1;H[B]=C,C=v}for(let B=0;B<65537;++B){let v=x[B];v>0&&(x[B]=v|H[v]++<<6)}}function Y(x,C,B,v,F,z){let R=C,U=0,W=0;for(;v<=F;v++){if(R.value-C.value>B)return!1;O(6,U,W,x,R);let X=L.l;if(U=L.c,W=L.lc,z[v]=X,X==63){if(R.value-C.value>B)throw new Error("Something wrong with hufUnpackEncTable");O(8,U,W,x,R);let Z=L.l+6;if(U=L.c,W=L.lc,v+Z>F+1)throw new Error("Something wrong with hufUnpackEncTable");for(;Z--;)z[v++]=0;v--}else if(X>=59){let Z=X-59+2;if(v+Z>F+1)throw new Error("Something wrong with hufUnpackEncTable");for(;Z--;)z[v++]=0;v--}}q(z)}function he(x){return x&63}function j(x){return x>>6}function le(x,C,B,v){for(;C<=B;C++){let F=j(x[C]),z=he(x[C]);if(F>>z)throw new Error("Invalid table entry");if(z>14){let R=v[F>>z-14];if(R.len)throw new Error("Invalid table entry");if(R.lit++,R.p){let U=R.p;R.p=new Array(R.lit);for(let W=0;W<R.lit-1;++W)R.p[W]=U[W]}else R.p=new Array(1);R.p[R.lit-1]=C}else if(z){let R=0;for(let U=1<<14-z;U>0;U--){let W=v[(F<<14-z)+R];if(W.len||W.p)throw new Error("Invalid table entry");W.len=z,W.lit=C,R++}}}return!0}let ce={c:0,lc:0};function we(x,C,B,v){x=x<<8|ze(B,v),C+=8,ce.c=x,ce.lc=C}let Ce={c:0,lc:0};function ke(x,C,B,v,F,z,R,U,W){if(x==C){v<8&&(we(B,v,F,z),B=ce.c,v=ce.lc),v-=8;let X=B>>v;if(X=new Uint8Array([X])[0],U.value+X>W)return!1;let Z=R[U.value-1];for(;X-- >0;)R[U.value++]=Z}else if(U.value<W)R[U.value++]=x;else return!1;Ce.c=B,Ce.lc=v}function ct(x){return x&65535}function nt(x){let C=ct(x);return C>32767?C-65536:C}let K={a:0,b:0};function re(x,C){let B=nt(x),F=nt(C),z=B+(F&1)+(F>>1),R=z,U=z-F;K.a=R,K.b=U}function be(x,C){let B=ct(x),v=ct(C),F=B-(v>>1)&65535,z=v+F-32768&65535;K.a=z,K.b=F}function We(x,C,B,v,F,z,R){let U=R<16384,W=B>F?F:B,X=1,Z,Q;for(;X<=W;)X<<=1;for(X>>=1,Z=X,X>>=1;X>=1;){Q=0;let ee=Q+z*(F-Z),ne=z*X,ae=z*Z,oe=v*X,pe=v*Z,Me,Ne,Ue,Te;for(;Q<=ee;Q+=ae){let Ve=Q,ye=Q+v*(B-Z);for(;Ve<=ye;Ve+=pe){let lt=Ve+oe,Dt=Ve+ne,st=Dt+oe;U?(re(x[Ve+C],x[Dt+C]),Me=K.a,Ue=K.b,re(x[lt+C],x[st+C]),Ne=K.a,Te=K.b,re(Me,Ne),x[Ve+C]=K.a,x[lt+C]=K.b,re(Ue,Te),x[Dt+C]=K.a,x[st+C]=K.b):(be(x[Ve+C],x[Dt+C]),Me=K.a,Ue=K.b,be(x[lt+C],x[st+C]),Ne=K.a,Te=K.b,be(Me,Ne),x[Ve+C]=K.a,x[lt+C]=K.b,be(Ue,Te),x[Dt+C]=K.a,x[st+C]=K.b)}if(B&X){let lt=Ve+ne;U?re(x[Ve+C],x[lt+C]):be(x[Ve+C],x[lt+C]),Me=K.a,x[lt+C]=K.b,x[Ve+C]=Me}}if(F&X){let Ve=Q,ye=Q+v*(B-Z);for(;Ve<=ye;Ve+=pe){let lt=Ve+oe;U?re(x[Ve+C],x[lt+C]):be(x[Ve+C],x[lt+C]),Me=K.a,x[lt+C]=K.b,x[Ve+C]=Me}}Z=X,X>>=1}return Q}function Pe(x,C,B,v,F,z,R,U,W){let X=0,Z=0,Q=R,ee=Math.trunc(v.value+(F+7)/8);for(;v.value<ee;)for(we(X,Z,B,v),X=ce.c,Z=ce.lc;Z>=14;){let ae=X>>Z-14&16383,oe=C[ae];if(oe.len)Z-=oe.len,ke(oe.lit,z,X,Z,B,v,U,W,Q),X=Ce.c,Z=Ce.lc;else{if(!oe.p)throw new Error("hufDecode issues");let pe;for(pe=0;pe<oe.lit;pe++){let Me=he(x[oe.p[pe]]);for(;Z<Me&&v.value<ee;)we(X,Z,B,v),X=ce.c,Z=ce.lc;if(Z>=Me&&j(x[oe.p[pe]])==(X>>Z-Me&(1<<Me)-1)){Z-=Me,ke(oe.p[pe],z,X,Z,B,v,U,W,Q),X=Ce.c,Z=Ce.lc;break}}if(pe==oe.lit)throw new Error("hufDecode issues")}}let ne=8-F&7;for(X>>=ne,Z-=ne;Z>0;){let ae=C[X<<14-Z&16383];if(ae.len)Z-=ae.len,ke(ae.lit,z,X,Z,B,v,U,W,Q),X=Ce.c,Z=Ce.lc;else throw new Error("hufDecode issues")}return!0}function Qe(x,C,B,v,F,z){let R={value:0},U=B.value,W=Re(C,B),X=Re(C,B);B.value+=4;let Z=Re(C,B);if(B.value+=4,W<0||W>=65537||X<0||X>=65537)throw new Error("Something wrong with HUF_ENCSIZE");let Q=new Array(65537),ee=new Array(16384);P(ee);let ne=v-(B.value-U);if(Y(x,B,ne,W,X,Q),Z>8*(v-(B.value-U)))throw new Error("Something wrong with hufUncompress");le(Q,W,X,ee),Pe(Q,ee,x,B,Z,X,z,F,R)}function Rt(x,C,B){for(let v=0;v<B;++v)C[v]=x[C[v]]}function tt(x){for(let C=1;C<x.length;C++){let B=x[C-1]+x[C]-128;x[C]=B}}function wt(x,C){let B=0,v=Math.floor((x.length+1)/2),F=0,z=x.length-1;for(;!(F>z||(C[F++]=x[B++],F>z));)C[F++]=x[v++]}function G(x){let C=x.byteLength,B=new Array,v=0,F=new DataView(x);for(;C>0;){let z=F.getInt8(v++);if(z<0){let R=-z;C-=R+1;for(let U=0;U<R;U++)B.push(F.getUint8(v++))}else{let R=z;C-=2;let U=F.getUint8(v++);for(let W=0;W<R+1;W++)B.push(U)}}return B}function at(x,C,B,v,F,z){let R=new DataView(z.buffer),U=B[x.idx[0]].width,W=B[x.idx[0]].height,X=3,Z=Math.floor(U/8),Q=Math.ceil(U/8),ee=Math.ceil(W/8),ne=U-(Q-1)*8,ae=W-(ee-1)*8,oe={value:0},pe=new Array(X),Me=new Array(X),Ne=new Array(X),Ue=new Array(X),Te=new Array(X);for(let ye=0;ye<X;++ye)Te[ye]=C[x.idx[ye]],pe[ye]=ye<1?0:pe[ye-1]+Q*ee,Me[ye]=new Float32Array(64),Ne[ye]=new Uint16Array(64),Ue[ye]=new Uint16Array(Q*64);for(let ye=0;ye<ee;++ye){let lt=8;ye==ee-1&&(lt=ae);let Dt=8;for(let it=0;it<Q;++it){it==Q-1&&(Dt=ne);for(let Ge=0;Ge<X;++Ge)Ne[Ge].fill(0),Ne[Ge][0]=F[pe[Ge]++],yt(oe,v,Ne[Ge]),Ae(Ne[Ge],Me[Ge]),It(Me[Ge]);X==3&&Be(Me);for(let Ge=0;Ge<X;++Ge)$e(Me[Ge],Ue[Ge],it*64)}let st=0;for(let it=0;it<X;++it){let Ge=B[x.idx[it]].type;for(let Nt=8*ye;Nt<8*ye+lt;++Nt){st=Te[it][Nt];for(let jt=0;jt<Z;++jt){let Pt=jt*64+(Nt&7)*8;R.setUint16(st+0*Ge,Ue[it][Pt+0],!0),R.setUint16(st+2*Ge,Ue[it][Pt+1],!0),R.setUint16(st+4*Ge,Ue[it][Pt+2],!0),R.setUint16(st+6*Ge,Ue[it][Pt+3],!0),R.setUint16(st+8*Ge,Ue[it][Pt+4],!0),R.setUint16(st+10*Ge,Ue[it][Pt+5],!0),R.setUint16(st+12*Ge,Ue[it][Pt+6],!0),R.setUint16(st+14*Ge,Ue[it][Pt+7],!0),st+=16*Ge}}if(Z!=Q)for(let Nt=8*ye;Nt<8*ye+lt;++Nt){let jt=Te[it][Nt]+8*Z*2*Ge,Pt=Z*64+(Nt&7)*8;for(let qt=0;qt<Dt;++qt)R.setUint16(jt+qt*2*Ge,Ue[it][Pt+qt],!0)}}}let Ve=new Uint16Array(U);R=new DataView(z.buffer);for(let ye=0;ye<X;++ye){B[x.idx[ye]].decoded=!0;let lt=B[x.idx[ye]].type;if(B[ye].type==2)for(let Dt=0;Dt<W;++Dt){let st=Te[ye][Dt];for(let it=0;it<U;++it)Ve[it]=R.getUint16(st+it*2*lt,!0);for(let it=0;it<U;++it)R.setFloat32(st+it*2*lt,J(Ve[it]),!0)}}}function ot(x,C,B,v,F,z){let R=new DataView(z.buffer),U=B[x],W=U.width,X=U.height,Z=Math.ceil(W/8),Q=Math.ceil(X/8),ee=Math.floor(W/8),ne=W-(Z-1)*8,ae=X-(Q-1)*8,oe={value:0},pe=0,Me=new Float32Array(64),Ne=new Uint16Array(64),Ue=new Uint16Array(Z*64);for(let Te=0;Te<Q;++Te){let Ve=8;Te==Q-1&&(Ve=ae);for(let ye=0;ye<Z;++ye)Ne.fill(0),Ne[0]=F[pe++],yt(oe,v,Ne),Ae(Ne,Me),It(Me),$e(Me,Ue,ye*64);for(let ye=8*Te;ye<8*Te+Ve;++ye){let lt=C[x][ye];for(let Dt=0;Dt<ee;++Dt){let st=Dt*64+(ye&7)*8;for(let it=0;it<8;++it)R.setUint16(lt+it*2*U.type,Ue[st+it],!0);lt+=16*U.type}if(Z!=ee){let Dt=ee*64+(ye&7)*8;for(let st=0;st<ne;++st)R.setUint16(lt+st*2*U.type,Ue[Dt+st],!0)}}}U.decoded=!0}function yt(x,C,B){let v,F=1;for(;F<64;)v=C[x.value],v==65280?F=64:v>>8==255?F+=v&255:(B[F]=v,F++),x.value++}function Ae(x,C){C[0]=J(x[0]),C[1]=J(x[1]),C[2]=J(x[5]),C[3]=J(x[6]),C[4]=J(x[14]),C[5]=J(x[15]),C[6]=J(x[27]),C[7]=J(x[28]),C[8]=J(x[2]),C[9]=J(x[4]),C[10]=J(x[7]),C[11]=J(x[13]),C[12]=J(x[16]),C[13]=J(x[26]),C[14]=J(x[29]),C[15]=J(x[42]),C[16]=J(x[3]),C[17]=J(x[8]),C[18]=J(x[12]),C[19]=J(x[17]),C[20]=J(x[25]),C[21]=J(x[30]),C[22]=J(x[41]),C[23]=J(x[43]),C[24]=J(x[9]),C[25]=J(x[11]),C[26]=J(x[18]),C[27]=J(x[24]),C[28]=J(x[31]),C[29]=J(x[40]),C[30]=J(x[44]),C[31]=J(x[53]),C[32]=J(x[10]),C[33]=J(x[19]),C[34]=J(x[23]),C[35]=J(x[32]),C[36]=J(x[39]),C[37]=J(x[45]),C[38]=J(x[52]),C[39]=J(x[54]),C[40]=J(x[20]),C[41]=J(x[22]),C[42]=J(x[33]),C[43]=J(x[38]),C[44]=J(x[46]),C[45]=J(x[51]),C[46]=J(x[55]),C[47]=J(x[60]),C[48]=J(x[21]),C[49]=J(x[34]),C[50]=J(x[37]),C[51]=J(x[47]),C[52]=J(x[50]),C[53]=J(x[56]),C[54]=J(x[59]),C[55]=J(x[61]),C[56]=J(x[35]),C[57]=J(x[36]),C[58]=J(x[48]),C[59]=J(x[49]),C[60]=J(x[57]),C[61]=J(x[58]),C[62]=J(x[62]),C[63]=J(x[63])}function It(x){let C=.5*Math.cos(.7853975),B=.5*Math.cos(3.14159/16),v=.5*Math.cos(3.14159/8),F=.5*Math.cos(3*3.14159/16),z=.5*Math.cos(5*3.14159/16),R=.5*Math.cos(3*3.14159/8),U=.5*Math.cos(7*3.14159/16),W=new Array(4),X=new Array(4),Z=new Array(4),Q=new Array(4);for(let ee=0;ee<8;++ee){let ne=ee*8;W[0]=v*x[ne+2],W[1]=R*x[ne+2],W[2]=v*x[ne+6],W[3]=R*x[ne+6],X[0]=B*x[ne+1]+F*x[ne+3]+z*x[ne+5]+U*x[ne+7],X[1]=F*x[ne+1]-U*x[ne+3]-B*x[ne+5]-z*x[ne+7],X[2]=z*x[ne+1]-B*x[ne+3]+U*x[ne+5]+F*x[ne+7],X[3]=U*x[ne+1]-z*x[ne+3]+F*x[ne+5]-B*x[ne+7],Z[0]=C*(x[ne+0]+x[ne+4]),Z[3]=C*(x[ne+0]-x[ne+4]),Z[1]=W[0]+W[3],Z[2]=W[1]-W[2],Q[0]=Z[0]+Z[1],Q[1]=Z[3]+Z[2],Q[2]=Z[3]-Z[2],Q[3]=Z[0]-Z[1],x[ne+0]=Q[0]+X[0],x[ne+1]=Q[1]+X[1],x[ne+2]=Q[2]+X[2],x[ne+3]=Q[3]+X[3],x[ne+4]=Q[3]-X[3],x[ne+5]=Q[2]-X[2],x[ne+6]=Q[1]-X[1],x[ne+7]=Q[0]-X[0]}for(let ee=0;ee<8;++ee)W[0]=v*x[16+ee],W[1]=R*x[16+ee],W[2]=v*x[48+ee],W[3]=R*x[48+ee],X[0]=B*x[8+ee]+F*x[24+ee]+z*x[40+ee]+U*x[56+ee],X[1]=F*x[8+ee]-U*x[24+ee]-B*x[40+ee]-z*x[56+ee],X[2]=z*x[8+ee]-B*x[24+ee]+U*x[40+ee]+F*x[56+ee],X[3]=U*x[8+ee]-z*x[24+ee]+F*x[40+ee]-B*x[56+ee],Z[0]=C*(x[ee]+x[32+ee]),Z[3]=C*(x[ee]-x[32+ee]),Z[1]=W[0]+W[3],Z[2]=W[1]-W[2],Q[0]=Z[0]+Z[1],Q[1]=Z[3]+Z[2],Q[2]=Z[3]-Z[2],Q[3]=Z[0]-Z[1],x[0+ee]=Q[0]+X[0],x[8+ee]=Q[1]+X[1],x[16+ee]=Q[2]+X[2],x[24+ee]=Q[3]+X[3],x[32+ee]=Q[3]-X[3],x[40+ee]=Q[2]-X[2],x[48+ee]=Q[1]-X[1],x[56+ee]=Q[0]-X[0]}function Be(x){for(let C=0;C<64;++C){let B=x[0][C],v=x[1][C],F=x[2][C];x[0][C]=B+1.5747*F,x[1][C]=B-.1873*v-.4682*F,x[2][C]=B+1.8556*v}}function $e(x,C,B){for(let v=0;v<64;++v)C[B+v]=Ot.toHalfFloat(N(x[v]))}function N(x){return x<=1?Math.sign(x)*Math.pow(Math.abs(x),2.2):Math.sign(x)*Math.pow(T,Math.abs(x)-1)}function E(x){return new DataView(x.array.buffer,x.offset.value,x.size)}function $(x){let C=x.viewer.buffer.slice(x.offset.value,x.offset.value+x.size),B=new Uint8Array(G(C)),v=new Uint8Array(B.length);return tt(B),wt(B,v),new DataView(v.buffer)}function ie(x){let C=x.array.slice(x.offset.value,x.offset.value+x.size),B=Ia(C),v=new Uint8Array(B.length);return tt(B),wt(B,v),new DataView(v.buffer)}function ue(x){let C=x.viewer,B={value:x.offset.value},v=new Uint16Array(x.columns*x.lines*(x.inputChannels.length*x.type)),F=new Uint8Array(8192),z=0,R=new Array(x.inputChannels.length);for(let ae=0,oe=x.inputChannels.length;ae<oe;ae++)R[ae]={},R[ae].start=z,R[ae].end=R[ae].start,R[ae].nx=x.columns,R[ae].ny=x.lines,R[ae].size=x.type,z+=R[ae].nx*R[ae].ny*R[ae].size;let U=ge(C,B),W=ge(C,B);if(W>=8192)throw new Error("Something is wrong with PIZ_COMPRESSION BITMAP_SIZE");if(U<=W)for(let ae=0;ae<W-U+1;ae++)F[ae+U]=ve(C,B);let X=new Uint16Array(65536),Z=S(F,X),Q=Re(C,B);Qe(x.array,C,B,Q,v,z);for(let ae=0;ae<x.inputChannels.length;++ae){let oe=R[ae];for(let pe=0;pe<R[ae].size;++pe)We(v,oe.start+pe,oe.nx,oe.size,oe.ny,oe.nx*oe.size,Z)}Rt(X,v,z);let ee=0,ne=new Uint8Array(v.buffer.byteLength);for(let ae=0;ae<x.lines;ae++)for(let oe=0;oe<x.inputChannels.length;oe++){let pe=R[oe],Me=pe.nx*pe.size,Ne=new Uint8Array(v.buffer,pe.end*2,Me*2);ne.set(Ne,ee),ee+=Me*2,pe.end+=Me}return new DataView(ne.buffer)}function te(x){let C=x.array.slice(x.offset.value,x.offset.value+x.size),B=Ia(C),v=x.inputChannels.length*x.lines*x.columns*x.totalBytes,F=new ArrayBuffer(v),z=new DataView(F),R=0,U=0,W=new Array(4);for(let X=0;X<x.lines;X++)for(let Z=0;Z<x.inputChannels.length;Z++){let Q=0;switch(x.inputChannels[Z].pixelType){case 1:W[0]=R,W[1]=W[0]+x.columns,R=W[1]+x.columns;for(let ne=0;ne<x.columns;++ne){let ae=B[W[0]++]<<8|B[W[1]++];Q+=ae,z.setUint16(U,Q,!0),U+=2}break;case 2:W[0]=R,W[1]=W[0]+x.columns,W[2]=W[1]+x.columns,R=W[2]+x.columns;for(let ne=0;ne<x.columns;++ne){let ae=B[W[0]++]<<24|B[W[1]++]<<16|B[W[2]++]<<8;Q+=ae,z.setUint32(U,Q,!0),U+=4}break}}return z}function Fe(x){let C=x.viewer,B={value:x.offset.value},v=new Uint8Array(x.columns*x.lines*(x.inputChannels.length*x.type*2)),F={version:Ie(C,B),unknownUncompressedSize:Ie(C,B),unknownCompressedSize:Ie(C,B),acCompressedSize:Ie(C,B),dcCompressedSize:Ie(C,B),rleCompressedSize:Ie(C,B),rleUncompressedSize:Ie(C,B),rleRawSize:Ie(C,B),totalAcUncompressedCount:Ie(C,B),totalDcUncompressedCount:Ie(C,B),acCompression:Ie(C,B)};if(F.version<2)throw new Error("EXRLoader.parse: "+ri.compression+" version "+F.version+" is unsupported");let z=new Array,R=ge(C,B)-2;for(;R>0;){let oe=xe(C.buffer,B),pe=ve(C,B),Me=pe>>2&3,Ne=(pe>>4)-1,Ue=new Int8Array([Ne])[0],Te=ve(C,B);z.push({name:oe,index:Ue,type:Te,compression:Me}),R-=oe.length+3}let U=ri.channels,W=new Array(x.inputChannels.length);for(let oe=0;oe<x.inputChannels.length;++oe){let pe=W[oe]={},Me=U[oe];pe.name=Me.name,pe.compression=0,pe.decoded=!1,pe.type=Me.pixelType,pe.pLinear=Me.pLinear,pe.width=x.columns,pe.height=x.lines}let X={idx:new Array(3)};for(let oe=0;oe<x.inputChannels.length;++oe){let pe=W[oe];for(let Me=0;Me<z.length;++Me){let Ne=z[Me];pe.name==Ne.name&&(pe.compression=Ne.compression,Ne.index>=0&&(X.idx[Ne.index]=oe),pe.offset=oe)}}let Z,Q,ee;if(F.acCompressedSize>0)switch(F.acCompression){case 0:Z=new Uint16Array(F.totalAcUncompressedCount),Qe(x.array,C,B,F.acCompressedSize,Z,F.totalAcUncompressedCount);break;case 1:let oe=x.array.slice(B.value,B.value+F.totalAcUncompressedCount),pe=Ia(oe);Z=new Uint16Array(pe.buffer),B.value+=F.totalAcUncompressedCount;break}if(F.dcCompressedSize>0){let oe={array:x.array,offset:B,size:F.dcCompressedSize};Q=new Uint16Array(ie(oe).buffer),B.value+=F.dcCompressedSize}if(F.rleRawSize>0){let oe=x.array.slice(B.value,B.value+F.rleCompressedSize),pe=Ia(oe);ee=G(pe.buffer),B.value+=F.rleCompressedSize}let ne=0,ae=new Array(W.length);for(let oe=0;oe<ae.length;++oe)ae[oe]=new Array;for(let oe=0;oe<x.lines;++oe)for(let pe=0;pe<W.length;++pe)ae[pe].push(ne),ne+=W[pe].width*x.type*2;X.idx[0]!==void 0&&W[X.idx[0]]&&at(X,ae,W,Z,Q,v);for(let oe=0;oe<W.length;++oe){let pe=W[oe];if(!pe.decoded)switch(pe.compression){case 2:let Me=0,Ne=0;for(let Ue=0;Ue<x.lines;++Ue){let Te=ae[oe][Me];for(let Ve=0;Ve<pe.width;++Ve){for(let ye=0;ye<2*pe.type;++ye)v[Te++]=ee[Ne+ye*pe.width*pe.height];Ne++}Me++}break;case 1:ot(oe,ae,W,Z,Q,v);break;default:throw new Error("EXRLoader.parse: unsupported channel compression")}}return new DataView(v.buffer)}function xe(x,C){let B=new Uint8Array(x),v=0;for(;B[C.value+v]!=0;)v+=1;let F=new TextDecoder().decode(B.slice(C.value,C.value+v));return C.value=C.value+v+1,F}function Oe(x,C,B){let v=new TextDecoder().decode(new Uint8Array(x).slice(C.value,C.value+B));return C.value=C.value+B,v}function De(x,C){let B=de(x,C),v=Re(x,C);return[B,v]}function fe(x,C){let B=Re(x,C),v=Re(x,C);return[B,v]}function de(x,C){let B=x.getInt32(C.value,!0);return C.value=C.value+4,B}function Re(x,C){let B=x.getUint32(C.value,!0);return C.value=C.value+4,B}function ze(x,C){let B=x[C.value];return C.value=C.value+1,B}function ve(x,C){let B=x.getUint8(C.value);return C.value=C.value+1,B}let Ie=function(x,C){let B;return"getBigInt64"in DataView.prototype?B=Number(x.getBigInt64(C.value,!0)):B=x.getUint32(C.value+4,!0)+Number(x.getUint32(C.value,!0)<<32),C.value+=8,B};function V(x,C){let B=x.getFloat32(C.value,!0);return C.value+=4,B}function _e(x,C){return Ot.toHalfFloat(V(x,C))}function J(x){let C=(x&31744)>>10,B=x&1023;return(x>>15?-1:1)*(C?C===31?B?NaN:1/0:Math.pow(2,C-15)*(1+B/1024):6103515625e-14*(B/1024))}function ge(x,C){let B=x.getUint16(C.value,!0);return C.value+=2,B}function me(x,C){return J(ge(x,C))}function se(x,C,B,v){let F=B.value,z=[];for(;B.value<F+v-1;){let R=xe(C,B),U=de(x,B),W=ve(x,B);B.value+=3;let X=de(x,B),Z=de(x,B);z.push({name:R,pixelType:U,pLinear:W,xSampling:X,ySampling:Z})}return B.value+=1,z}function Ee(x,C){let B=V(x,C),v=V(x,C),F=V(x,C),z=V(x,C),R=V(x,C),U=V(x,C),W=V(x,C),X=V(x,C);return{redX:B,redY:v,greenX:F,greenY:z,blueX:R,blueY:U,whiteX:W,whiteY:X}}function Je(x,C){let B=["NO_COMPRESSION","RLE_COMPRESSION","ZIPS_COMPRESSION","ZIP_COMPRESSION","PIZ_COMPRESSION","PXR24_COMPRESSION","B44_COMPRESSION","B44A_COMPRESSION","DWAA_COMPRESSION","DWAB_COMPRESSION"],v=ve(x,C);return B[v]}function At(x,C){let B=de(x,C),v=de(x,C),F=de(x,C),z=de(x,C);return{xMin:B,yMin:v,xMax:F,yMax:z}}function vt(x,C){let B=["INCREASING_Y","DECREASING_Y","RANDOM_Y"],v=ve(x,C);return B[v]}function Fn(x,C){let B=["ENVMAP_LATLONG","ENVMAP_CUBE"],v=ve(x,C);return B[v]}function An(x,C){let B=["ONE_LEVEL","MIPMAP_LEVELS","RIPMAP_LEVELS"],v=["ROUND_DOWN","ROUND_UP"],F=Re(x,C),z=Re(x,C),R=ve(x,C);return{xSize:F,ySize:z,levelMode:B[R&15],roundingMode:v[R>>4]}}function Pl(x,C){let B=V(x,C),v=V(x,C);return[B,v]}function Da(x,C){let B=V(x,C),v=V(x,C),F=V(x,C);return[B,v,F]}function Fa(x,C,B,v,F){if(v==="string"||v==="stringvector"||v==="iccProfile")return Oe(C,B,F);if(v==="chlist")return se(x,C,B,F);if(v==="chromaticities")return Ee(x,B);if(v==="compression")return Je(x,B);if(v==="box2i")return At(x,B);if(v==="envmap")return Fn(x,B);if(v==="tiledesc")return An(x,B);if(v==="lineOrder")return vt(x,B);if(v==="float")return V(x,B);if(v==="v2f")return Pl(x,B);if(v==="v3f")return Da(x,B);if(v==="int")return de(x,B);if(v==="rational")return De(x,B);if(v==="timecode")return fe(x,B);if(v==="preview")return B.value+=F,"skipped";B.value+=F}function ii(x,C){let B=Math.log2(x);return C=="ROUND_DOWN"?Math.floor(B):Math.ceil(B)}function Ts(x,C,B){let v=0;switch(x.levelMode){case"ONE_LEVEL":v=1;break;case"MIPMAP_LEVELS":v=ii(Math.max(C,B),x.roundingMode)+1;break;case"RIPMAP_LEVELS":throw new Error("THREE.EXRLoader: RIPMAP_LEVELS tiles currently unsupported.")}return v}function ws(x,C,B,v){let F=new Array(x);for(let z=0;z<x;z++){let R=1<<z,U=C/R|0;v=="ROUND_UP"&&U*R<C&&(U+=1);let W=Math.max(U,1);F[z]=(W+B-1)/B|0}return F}function La(){let x=this,C=x.offset,B={value:0};for(let v=0;v<x.tileCount;v++){let F=de(x.viewer,C),z=de(x.viewer,C);C.value+=8,x.size=Re(x.viewer,C);let R=F*x.blockWidth,U=z*x.blockHeight;x.columns=R+x.blockWidth>x.width?x.width-R:x.blockWidth,x.lines=U+x.blockHeight>x.height?x.height-U:x.blockHeight;let W=x.columns*x.totalBytes,Z=x.size<x.lines*W?x.uncompress(x):E(x);C.value+=x.size;for(let Q=0;Q<x.lines;Q++){let ee=Q*x.columns*x.totalBytes;for(let ne=0;ne<x.inputChannels.length;ne++){let ae=ri.channels[ne].name,oe=x.channelByteOffsets[ae]*x.columns,pe=x.decodeChannels[ae];if(pe===void 0)continue;B.value=ee+oe;let Me=(x.height-(1+U+Q))*x.outLineWidth;for(let Ne=0;Ne<x.columns;Ne++){let Ue=Me+(Ne+R)*x.outputChannels+pe;x.byteArray[Ue]=x.getter(Z,B)}}}}}function br(){let x=this,C=x.offset,B={value:0};for(let v=0;v<x.height/x.blockHeight;v++){let F=de(x.viewer,C)-ri.dataWindow.yMin;x.size=Re(x.viewer,C),x.lines=F+x.blockHeight>x.height?x.height-F:x.blockHeight;let z=x.columns*x.totalBytes,U=x.size<x.lines*z?x.uncompress(x):E(x);C.value+=x.size;for(let W=0;W<x.blockHeight;W++){let X=v*x.blockHeight,Z=W+x.scanOrder(X);if(Z>=x.height)continue;let Q=W*z,ee=(x.height-1-Z)*x.outLineWidth;for(let ne=0;ne<x.inputChannels.length;ne++){let ae=ri.channels[ne].name,oe=x.channelByteOffsets[ae]*x.columns,pe=x.decodeChannels[ae];if(pe!==void 0){B.value=Q+oe;for(let Me=0;Me<x.columns;Me++){let Ne=ee+Me*x.outputChannels+pe;x.byteArray[Ne]=x.getter(U,B)}}}}}}function Na(x,C,B){let v={};if(x.getUint32(0,!0)!=20000630)throw new Error("THREE.EXRLoader: Provided file doesn't appear to be in OpenEXR format.");v.version=x.getUint8(4);let F=x.getUint8(5);v.spec={singleTile:!!(F&2),longName:!!(F&4),deepFormat:!!(F&8),multiPart:!!(F&16)},B.value=8;let z=!0;for(;z;){let R=xe(C,B);if(R==="")z=!1;else{let U=xe(C,B),W=Re(x,B),X=Fa(x,C,B,U,W);X===void 0?console.warn(`THREE.EXRLoader: Skipped unknown header attribute type '${U}'.`):v[R]=X}}if((F&-7)!=0)throw console.error("THREE.EXRHeader:",v),new Error("THREE.EXRLoader: Provided file is currently unsupported.");return v}function Sr(x,C,B,v,F,z){let R={size:0,viewer:C,array:B,offset:v,width:x.dataWindow.xMax-x.dataWindow.xMin+1,height:x.dataWindow.yMax-x.dataWindow.yMin+1,inputChannels:x.channels,channelByteOffsets:{},shouldExpand:!1,scanOrder:null,totalBytes:null,columns:null,lines:null,type:null,uncompress:null,getter:null,format:null,colorSpace:Gt};switch(x.compression){case"NO_COMPRESSION":R.blockHeight=1,R.uncompress=E;break;case"RLE_COMPRESSION":R.blockHeight=1,R.uncompress=$;break;case"ZIPS_COMPRESSION":R.blockHeight=1,R.uncompress=ie;break;case"ZIP_COMPRESSION":R.blockHeight=16,R.uncompress=ie;break;case"PIZ_COMPRESSION":R.blockHeight=32,R.uncompress=ue;break;case"PXR24_COMPRESSION":R.blockHeight=16,R.uncompress=te;break;case"DWAA_COMPRESSION":R.blockHeight=32,R.uncompress=Fe;break;case"DWAB_COMPRESSION":R.blockHeight=256,R.uncompress=Fe;break;default:throw new Error("EXRLoader.parse: "+x.compression+" is unsupported")}let U={};for(let ee of x.channels)switch(ee.name){case"Y":case"R":case"G":case"B":case"A":U[ee.name]=!0,R.type=ee.pixelType}let W=!1,X=!1;if(U.R&&U.G&&U.B)R.outputChannels=4;else if(U.Y)R.outputChannels=1;else throw new Error("EXRLoader.parse: file contains unsupported data channels.");switch(R.outputChannels){case 4:z==He?(W=!U.A,R.format=He,R.colorSpace=Gt,R.outputChannels=4,R.decodeChannels={R:0,G:1,B:2,A:3}):z==Tn?(R.format=Tn,R.colorSpace=Gt,R.outputChannels=2,R.decodeChannels={R:0,G:1}):z==vn?(R.format=vn,R.colorSpace=Gt,R.outputChannels=1,R.decodeChannels={R:0}):X=!0;break;case 1:z==He?(W=!0,R.format=He,R.colorSpace=Gt,R.outputChannels=4,R.shouldExpand=!0,R.decodeChannels={Y:0}):z==Tn?(R.format=Tn,R.colorSpace=Gt,R.outputChannels=2,R.shouldExpand=!0,R.decodeChannels={Y:0}):z==vn?(R.format=vn,R.colorSpace=Gt,R.outputChannels=1,R.decodeChannels={Y:0}):X=!0;break;default:X=!0}if(X)throw new Error("EXRLoader.parse: invalid output format for specified file.");if(R.type==1)switch(F){case qe:R.getter=me;break;case _t:R.getter=ge;break}else if(R.type==2)switch(F){case qe:R.getter=V;break;case _t:R.getter=_e}else throw new Error("EXRLoader.parse: unsupported pixelType "+R.type+" for "+x.compression+".");R.columns=R.width;let Z=R.width*R.height*R.outputChannels;switch(F){case qe:R.byteArray=new Float32Array(Z),W&&R.byteArray.fill(1,0,Z);break;case _t:R.byteArray=new Uint16Array(Z),W&&R.byteArray.fill(15360,0,Z);break;default:console.error("THREE.EXRLoader: unsupported type: ",F);break}let Q=0;for(let ee of x.channels)R.decodeChannels[ee.name]!==void 0&&(R.channelByteOffsets[ee.name]=Q),Q+=ee.pixelType*2;if(R.totalBytes=Q,R.outLineWidth=R.width*R.outputChannels,x.lineOrder==="INCREASING_Y"?R.scanOrder=ee=>ee:R.scanOrder=ee=>R.height-1-ee,x.spec.singleTile){R.blockHeight=x.tiles.ySize,R.blockWidth=x.tiles.xSize;let ee=Ts(x.tiles,R.width,R.height),ne=ws(ee,R.width,x.tiles.xSize,x.tiles.roundingMode),ae=ws(ee,R.height,x.tiles.ySize,x.tiles.roundingMode);R.tileCount=ne[0]*ae[0];for(let oe=0;oe<ee;oe++)for(let pe=0;pe<ae[oe];pe++)for(let Me=0;Me<ne[oe];Me++)Ie(C,v);R.decode=La.bind(R)}else{R.blockWidth=R.width;let ee=Math.ceil(R.height/R.blockHeight);for(let ne=0;ne<ee;ne++)Ie(C,v);R.decode=br.bind(R)}return R}let As={value:0},Es=new DataView(e),Dl=new Uint8Array(e),ri=Na(Es,e,As),Qn=Sr(ri,Es,Dl,As,this.type,this.outputFormat);if(Qn.decode(),Qn.shouldExpand){let x=Qn.byteArray;if(this.outputFormat==He)for(let C=0;C<x.length;C+=4)x[C+2]=x[C+1]=x[C];else if(this.outputFormat==Tn)for(let C=0;C<x.length;C+=2)x[C+1]=x[C]}return{header:ri,width:Qn.width,height:Qn.height,data:Qn.byteArray,format:Qn.format,colorSpace:Qn.colorSpace,type:this.type}}setDataType(e){return this.type=e,this}setOutputFormat(e){return this.outputFormat=e,this}load(e,t,n,r){function s(a,o){a.colorSpace=o.colorSpace,a.minFilter=ft,a.magFilter=ft,a.generateMipmaps=!1,a.flipY=!1,t&&t(a,o)}return super.load(e,s,n,r)}};var Cl="three-gpu-pathtracer-webgl2",Nh="0.0.24-three0.181.1-bvh0.9.5",ab=new URL(location.href).searchParams.get("session"),bm=64*1024*1024,ni=!1,Kn,yn,Dn,Rl=[],Il=0,ob=0,Pa=new Set,cb=window.webkit?.messageHandlers?.cadNativeRender,Ss=i=>cb.postMessage({...i,session:ab}),On=(i,e)=>{if(!i)throw new Error(e)},lb=()=>new Promise(i=>setTimeout(i,0)),Sm=i=>Uint8Array.from(atob(i),e=>e.charCodeAt(0)),bs=i=>new Ye().setRGB(...i,Gt);function Uh(){if(!ni){ni=!0,yn?.dispose();for(let i of Pa)i.dispose?.();Pa.clear(),Kn?.dispose(),Kn?.forceContextLoss(),Kn?.domElement.remove(),Rl=[],Il=0}}async function Ms(i){ni||await Ss({kind:"error",message:String(i?.message||i).slice(0,1e3)}).catch(()=>{}),Uh()}async function ym(i,e,t=!1){On(typeof e[i]=="string","The frozen scene image is missing.");let n=Sm(e[i]),r;if(/\.(hdr|exr)$/.test(i)){let a=(i.endsWith(".hdr")?new Al:new El).setDataType(qe).parse(n.buffer);r=new St(a.data,a.width,a.height,He,a.type),r.colorSpace=Gt}else{let s=URL.createObjectURL(new Blob([n],{type:i.endsWith(".png")?"image/png":"image/jpeg"}));try{r=await new Zs().loadAsync(s)}finally{URL.revokeObjectURL(s)}r.colorSpace=t?Gt:ln}return r.needsUpdate=!0,Pa.add(r),r}async function ub(i){On(i.schemaVersion===1&&i.backend===Cl,"Unsupported frozen render input.");let e=i.settings,t=i.scene;On([e.width,e.height].every(d=>Number.isInteger(d)&&d>=64&&d<=4096)&&e.width*e.height<=8388608,"Invalid image size.");let n={preview:16,studio:64,final:256}[e.quality];On(n&&Number.isFinite(e.exposureEV)&&Math.abs(e.exposureEV)<=6,"Invalid render settings."),On(Number.isInteger(e.maximumBounces)&&e.maximumBounces>=2&&e.maximumBounces<=16,"Invalid bounce count."),On(t.meshes.length>0&&t.meshes.reduce((d,_)=>d+_.indices.length/3,0)<=25e4,"The local scene is too large.");let r=document.createElement("canvas");document.body.append(r);let s=r.getContext("webgl2",{preserveDrawingBuffer:!0,antialias:!1,alpha:!1});On(s&&s.getExtension("EXT_color_buffer_float"),"Local WebGL2 floating-point rendering is unavailable.");let a=Math.min(s.getParameter(s.MAX_TEXTURE_SIZE),s.getParameter(s.MAX_RENDERBUFFER_SIZE));On(e.width<=a&&e.height<=a,"Choose a smaller image for this device."),r.addEventListener("webglcontextlost",d=>{d.preventDefault(),ni||Ms(new Error("The local graphics context was released. Try a smaller image."))}),Kn=new mc({canvas:r,context:s,antialias:!1,preserveDrawingBuffer:!0}),Kn.debug.onShaderError=()=>{Ms(new Error("The local path tracing shader could not be compiled. Try a smaller scene."))},Kn.setPixelRatio(1),Kn.setSize(e.width,e.height,!1),Kn.outputColorSpace=ln,Kn.toneMapping=Fo,Kn.toneMappingExposure=.001*Math.pow(2,e.exposureEV),Dn=new ir,Dn.background=bs(t.backgroundColor);let o=e.width/e.height,c=t.camera,u=c.orthographicHalfHeight?new pi(-c.orthographicHalfHeight*o,c.orthographicHalfHeight*o,c.orthographicHalfHeight,-c.orthographicHalfHeight,1e-4,1e9):new kt(c.verticalFOV,o,1e-4,1e9);u.position.fromArray(c.eye),u.up.fromArray(c.up),u.lookAt(new k().fromArray(c.target));let f=new Map;for(let d of t.meshes){if(ni)return;let _=new Bt;Pa.add(_),_.setAttribute("position",new tn(d.positions,3)),_.setIndex(new nr(d.indices,1)),d.normals.length?_.setAttribute("normal",new tn(d.normals,3)):_.computeVertexNormals(),d.uvs.length&&_.setAttribute("uv",new tn(d.uvs,2));let y=d.material,M=new qs({color:bs(y.color),metalness:y.metallic,roughness:y.roughness,opacity:y.opacity,transparent:y.opacity<.999,emissive:bs(y.emissive),emissiveIntensity:1,side:fn});if(Pa.add(M),y.baseColorImage&&d.uvs.length){let w=`${y.baseColorImage}:${y.imageIsLinear}:${y.flipImageV}`;if(!f.has(w)){let A=await ym(y.baseColorImage,t.assets,y.imageIsLinear);A.flipY=y.flipImageV,f.set(w,A)}M.map=f.get(w)}Dn.add(new rn(_,M))}if(t.environmentImage){let d=await ym(t.environmentImage,t.assets,!1);d.mapping=ei,Dn.environment=d,Dn.environmentIntensity=t.environmentIntensity,Dn.environmentRotation.y=t.environmentRotation*Math.PI/180,t.environmentShowsBackground&&(Dn.background=d,Dn.backgroundIntensity=t.environmentIntensity,Dn.backgroundRotation.copy(Dn.environmentRotation))}for(let d of t.lights){if(!d.intensity||!d.color.some(y=>y>0))continue;let _;if(d.kind==="directional")_=new Qs(bs(d.color),d.intensity);else if(d.kind==="point")_=new Ks(bs(d.color)),_.power=d.intensity;else{if(!d.outerAngle)continue;_=new Js(bs(d.color)),_.power=d.intensity,_.angle=d.outerAngle*Math.PI/360,_.penumbra=1-d.innerAngle/d.outerAngle}_.position.fromArray(d.position),_.target&&(_.target.position.fromArray(d.position).add(new k().fromArray(d.direction)),Dn.add(_.target)),Dn.add(_)}yn=new wl(Kn),yn.rasterizeScene=!1,yn.dynamicLowRes=!1,yn.fadeDuration=0,yn.renderDelay=0,yn.minSamples=1,yn.bounces=e.maximumBounces,yn.tiles.set(3,3),yn.textureSize.set(512,512),yn.setScene(Dn,u);let h=0;for(;!ni&&yn.samples<n;)yn.renderSample(),performance.now()-h>700&&(h=performance.now(),await Ss({kind:"progress",samples:Math.floor(yn.samples),target:n})),await lb();if(ni)return;let l=Math.floor(yn.samples);On(l>=n,"The path tracer did not complete the requested samples.");let p=await new Promise(d=>r.toBlob(d,"image/png"));On(p&&p.size>0&&p.size<=bm,"The rendered PNG is missing or too large.");let g=await new Promise((d,_)=>{let y=new FileReader;y.onload=()=>d(y.result),y.onerror=_,y.readAsDataURL(p)}),b=g.slice(g.indexOf(",")+1),m=196608;await Ss({kind:"pngBegin",byteCount:p.size,samples:l,backend:Cl,revision:Nh});for(let d=0,_=0;d<b.length&&!ni;d+=m,_++)await Ss({kind:"pngChunk",index:_,data:b.slice(d,d+m)});ni||await Ss({kind:"complete",samples:l,backend:Cl,revision:Nh}),Uh()}window.FloeCADNativeRender={appendInput(i,e,t){On(!ni&&e===ob++,"Invalid frozen-input sequence.");let n=Sm(i);if(Il+=n.length,On(Il<=bm,"The frozen scene is too large."),Rl.push(n),t){let r=new Uint8Array(Il),s=0;for(let o of Rl)r.set(o,s),s+=o.length;Rl=[];let a=JSON.parse(new TextDecoder().decode(r));ub(a).catch(Ms)}return!0},dispose:Uh};window.addEventListener("error",i=>{Ms(i.error||new Error("The local renderer could not start."))});window.addEventListener("unhandledrejection",i=>{Ms(i.reason||new Error("The local renderer stopped."))});Ss({kind:"ready",backend:Cl,revision:Nh}).catch(Ms);})();
/*! Bundled license information:

three/build/three.core.js:
three/build/three.module.js:
  (**
   * @license
   * Copyright 2010-2025 Three.js Authors
   * SPDX-License-Identifier: MIT
   *)

three/examples/jsm/libs/fflate.module.js:
  (*!
  fflate - fast JavaScript compression/decompression
  <https://101arrowz.github.io/fflate>
  Licensed under MIT. https://github.com/101arrowz/fflate/blob/master/LICENSE
  version 0.8.2
  *)
*/
