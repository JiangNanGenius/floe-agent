// SPDX-License-Identifier: MPL-2.0
// Read-only, bounded holder checks use unchanged MIT MillSimSharp. No machine safety claim.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Numerics;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;
using MillSimSharp.Geometry;
using MillSimSharp.Simulation;
using MillSimSharp.IO;

public static class FixtureClearanceHost {
    const string Core="3405064ebc312dbe38bacfdfb0eea8015354447ae3f749e4089cb8f584d1351d";
    static volatile bool cancelled;
    static void Check(){if(cancelled)throw new OperationCanceledException();}
    static string Hash(string p)=>Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(p))).ToLowerInvariant();
    readonly record struct V(double X,double Y,double Z) {
        public static V operator +(V a,V b)=>new(a.X+b.X,a.Y+b.Y,a.Z+b.Z);
        public static V operator -(V a,V b)=>new(a.X-b.X,a.Y-b.Y,a.Z-b.Z);
        public static V operator *(V a,double b)=>new(a.X*b,a.Y*b,a.Z*b);
        public double Norm=>Math.Sqrt(Dot(this,this));
        public static double Dot(V a,V b)=>a.X*b.X+a.Y*b.Y+a.Z*b.Z;
        public V Unit()=>this*(1/Norm);
        public Vector3 Float()=>new((float)X,(float)Y,(float)Z);
        public double[] Array()=>new[]{X,Y,Z};
    }
    readonly record struct Q(double X,double Y,double Z,double W) {
        static double Dot(Q a,Q b)=>a.X*b.X+a.Y*b.Y+a.Z*b.Z+a.W*b.W;
        Q Unit(){double n=Math.Sqrt(Dot(this,this));return new(X/n,Y/n,Z/n,W/n);}
        public static Q From(V a){a=a.Unit();return a.Z< -1+1e-14?new(1,0,0,0):new Q(-a.Y,a.X,0,1+a.Z).Unit();}
        public static double Angle(Q a,Q b)=>2*Math.Acos(Math.Clamp(Math.Abs(Dot(a,b)),0,1));
        public static Q Mix(Q a,Q b,double t){double d=Dot(a,b);if(d<0){b=new(-b.X,-b.Y,-b.Z,-b.W);d=-d;}if(d>0.9999999999)return new Q(a.X*(1-t)+b.X*t,a.Y*(1-t)+b.Y*t,a.Z*(1-t)+b.Z*t,a.W*(1-t)+b.W*t).Unit();double x=Math.Acos(Math.Clamp(d,-1,1)),u=Math.Sin((1-t)*x)/Math.Sin(x),v=Math.Sin(t*x)/Math.Sin(x);return new(a.X*u+b.X*v,a.Y*u+b.Y*v,a.Z*u+b.Z*v,a.W*u+b.W*v);}
        public V Axis()=>new V(2*(X*Z+W*Y),2*(Y*Z-W*X),1-2*(X*X+Y*Y)).Unit();
    }
    readonly record struct Pose(V Tip,V Axis,Vector3 ActualTip,Vector3 ActualAxis,int Segment,int Index);
    static V Vec(JsonElement e){double[] v=e.EnumerateArray().Select(x=>x.GetDouble()).ToArray();if(v.Length!=3||v.Any(x=>!double.IsFinite(x)||Math.Abs(x)>100))throw new ArgumentException("bounded finite vector required");return new(v[0],v[1],v[2]);}
    static double Number(JsonElement e,string key,double lo,double hi){double x=e.GetProperty(key).GetDouble();if(!double.IsFinite(x)||x<lo||x>hi)throw new ArgumentException("bounded finite "+key+" required");return x;}
    static void Keys(JsonElement e,params string[] keys){if(e.ValueKind!=JsonValueKind.Object||e.EnumerateObject().Any(x=>!keys.Contains(x.Name)))throw new ArgumentException("unsupported fields");}
    static double Sdf(V point,Pose pose,double offset,double length,double radius){V v=point-pose.Tip;double h=V.Dot(v,pose.Axis),r=Math.Sqrt(Math.Max(0,V.Dot(v,v)-h*h))-radius,a=Math.Abs(h-offset-length/2)-length/2;return Math.Min(Math.Max(r,a),0)+Math.Sqrt(Math.Pow(Math.Max(r,0),2)+Math.Pow(Math.Max(a,0),2));}
    public static int Main(string[] args){try{return Run(args);}catch(Exception e){Console.Error.WriteLine(e);return e is OperationCanceledException?130:1;}}
    static int Run(string[] a){
        if(!RuntimeInformation.IsOSPlatform(OSPlatform.OSX)||RuntimeInformation.ProcessArchitecture!=Architecture.Arm64)throw new PlatformNotSupportedException("qualified component target is arm64 macOS only");
        if(a.Length!=7)throw new ArgumentException("motion-input motion-output fixtures new-output motion-SHA manifest-SHA fixtures-SHA");
        string input=Path.GetFullPath(a[0]),motionDir=Path.GetFullPath(a[1]),fixturesFile=Path.GetFullPath(a[2]),output=Path.GetFullPath(a[3]),manifestFile=Path.Combine(motionDir,"manifest.json");
        void Digests(){if(Hash(input)!=a[4]||Hash(manifestFile)!=a[5]||Hash(fixturesFile)!=a[6])throw new IOException("frozen motion/fixtures changed");}
        if(new FileInfo(input).Length>65536||new FileInfo(fixturesFile).Length>16384)throw new ArgumentException("input budget");
        Digests();if(Hash(typeof(ToolCollisionDetector).Assembly.Location)!=Core)throw new InvalidDataException("core SHA mismatch");
        if(Directory.Exists(output)||File.Exists(output))throw new IOException("output exists; never replace old results");
        using var timeout=new System.Threading.Timer(_=>cancelled=true,null,45000,System.Threading.Timeout.Infinite);
        Console.CancelKeyPress+=(_,e)=>{e.Cancel=true;cancelled=true;};
        using var motion=JsonDocument.Parse(File.ReadAllBytes(input));using var result=JsonDocument.Parse(File.ReadAllBytes(manifestFile));using var fixturesDoc=JsonDocument.Parse(File.ReadAllBytes(fixturesFile));
        var m=motion.RootElement;var r=result.RootElement;var f=fixturesDoc.RootElement;
        if(m.GetProperty("schema").GetString()!="floe.multi-axis-stock.v1"||r.GetProperty("schema").GetString()!="floe.multi-axis-stock-result.v1"||r.GetProperty("inputSHA256").GetString()!=a[4]||r.GetProperty("backend").GetProperty("coreSHA256").GetString()!=Core)throw new InvalidDataException("wrong motion lineage");
        Keys(f,"schema","units","holder","fixtures");if(f.GetProperty("schema").GetString()!="floe.holder-fixture.v1"||f.GetProperty("units").GetString()!="mm")throw new ArgumentException("fixture schema/units");
        foreach(var artifact in r.GetProperty("artifacts").EnumerateArray()){
            string name=artifact.GetProperty("path").GetString()!;
            if(Path.GetFileName(name)!=name)throw new InvalidDataException("artifact path");string file=Path.Combine(motionDir,name);
            if(Hash(file)!=artifact.GetProperty("sha256").GetString()||new FileInfo(file).Length!=artifact.GetProperty("bytes").GetInt64())throw new InvalidDataException("motion artifact changed");
        }
        var holder=f.GetProperty("holder");Keys(holder,"kind","radiusMM","lengthMM","offsetFromTipMM");if(holder.GetProperty("kind").GetString()!="noncutting-cylinder")throw new ArgumentException("only an explicit cylindrical noncutting part is modelled");
        double radius=Number(holder,"radiusMM",.5,12),length=Number(holder,"lengthMM",1,20),offset=Number(holder,"offsetFromTipMM",0,40);
        if(offset<m.GetProperty("tool").GetProperty("lengthMM").GetDouble())throw new ArgumentException("holder must start after cutting edge");
        var controls=m.GetProperty("poses").EnumerateArray().Select(x=>(Tip:Vec(x.GetProperty("tipMM")),Q:Q.From(Vec(x.GetProperty("axisTowardSpindle"))))).ToArray();
        if(controls.Length<2||controls.Length>9)throw new ArgumentException("pose budget");
        var steps=r.GetProperty("spans").EnumerateArray().Select(x=>x.GetProperty("steps").GetInt32()).ToArray();if(steps.Length!=controls.Length-1)throw new InvalidDataException("span count");
        var samples=new List<Pose>();double delta=0,maxNativeError=0,pointRadius=Math.Sqrt(radius*radius+(offset+length)*(offset+length));
        using(var trace=new StreamReader(Path.Combine(motionDir,"evaluated-poses.tsv"))){trace.ReadLine();for(int k=0;k<steps.Length;k++){
            int n=steps[k];if(n<1||n>1024)throw new InvalidDataException("step budget");
            delta=Math.Max(delta,(controls[k+1].Tip-controls[k].Tip).Norm/(2*n)+2*pointRadius*Math.Sin(Q.Angle(controls[k].Q,controls[k+1].Q)/(4*n)));
            for(int j=0;j<=n;j++){
                double t=j/(double)n;string[] fields=(trace.ReadLine()??"").Split('\t');if(fields.Length!=9||int.Parse(fields[0])!=k||int.Parse(fields[1])!=j||int.Parse(fields[2])!=n)throw new InvalidDataException("pose trace");
                double[] vals=fields.Skip(3).Select(x=>double.Parse(x,CultureInfo.InvariantCulture)).ToArray();if(vals.Any(x=>!double.IsFinite(x)))throw new InvalidDataException("nonfinite pose");
                V tip=controls[k].Tip*(1-t)+controls[k+1].Tip*t,axis=Q.Mix(controls[k].Q,controls[k+1].Q,t).Axis();V actualTip=new(vals[0],vals[1],vals[2]),actualAxis=new V(vals[3],vals[4],vals[5]).Unit();
                double pe=(tip-actualTip).Norm,ae=(axis-actualAxis).Norm;if(pe>1e-5||ae>2e-6)throw new InvalidDataException("native trajectory differs from frozen input");
                maxNativeError=Math.Max(maxNativeError,pe+pointRadius*ae);samples.Add(new(tip,axis,actualTip.Float(),actualAxis.Float(),k,j));
            }
        }if(trace.ReadLine()!=null)throw new InvalidDataException("extra poses");}
        var fixtureItems=f.GetProperty("fixtures").EnumerateArray().ToArray();if(fixtureItems.Length<1||fixtureItems.Length>8)throw new ArgumentException("fixture count budget");
        var ids=new HashSet<string>();var checks=new List<object>();var meshes=new List<(string,VoxelGrid)>();long totalCells=0;
        foreach(var fixture in fixtureItems){
            Check();Keys(fixture,"id","minMM","maxMM","resolutionMM");string id=fixture.GetProperty("id").GetString()!;
            if(string.IsNullOrEmpty(id)||id.Length>40||id.Any(c=>!(char.IsAsciiLetterOrDigit(c)||c=='-'))||!ids.Add(id))throw new ArgumentException("unique safe fixture ID required");
            V lo=Vec(fixture.GetProperty("minMM")),hi=Vec(fixture.GetProperty("maxMM"));double h=Number(fixture,"resolutionMM",.125,1);if(!new[]{.125,.25,.5,1.0}.Contains(h))throw new ArgumentException("fixture resolution");
            double[] ext=(hi-lo).Array();if(ext.Any(x=>x<=0||x/h!=Math.Round(x/h))||lo.Array().Concat(hi.Array()).Any(x=>(double)(float)x!=x))throw new ArgumentException("fixture must be an exact grid-aligned box");
            long cells=ext.Select(x=>(long)Math.Round(x/h)).Aggregate(1L,(x,y)=>checked(x*y));totalCells+=cells;if(totalCells>32768||totalCells*samples.Count>16000000)throw new ArgumentException("fixture/certificate budget");
            var grid=new VoxelGrid(new BoundingBox(lo.Float(),hi.Float()),(float)h){UseParallelRemoval=false};meshes.Add((id,grid));
            double rho=Math.Sqrt(3)*h/2,margin=delta+rho+maxNativeError+.001;
            var nominalGeometry=new FlatEndMillGeometry((float)radius,(float)length);var expandedGeometry=new FlatEndMillGeometry((float)(radius+margin),(float)(length+2*margin));
            bool sampledHit=false,expandedHit=false;double minSdf=double.PositiveInfinity;Pose witnessPose=default;V witness=default;
            foreach(var pose in samples){
                Check();sampledHit|=ToolCollisionDetector.IntersectsMaterial(grid,nominalGeometry,pose.ActualTip+pose.ActualAxis*(float)offset,pose.ActualAxis);
                expandedHit|=ToolCollisionDetector.IntersectsMaterial(grid,expandedGeometry,pose.ActualTip+pose.ActualAxis*(float)(offset-margin),pose.ActualAxis);
                var dims=grid.Dimensions;for(int z=0;z<dims.Z;z++)for(int y=0;y<dims.Y;y++)for(int x=0;x<dims.X;x++){
                    V centre=lo+new V(x+.5,y+.5,z+.5)*h;double sd=Sdf(centre,pose,offset,length,radius);if(sd<minSdf){minSdf=sd;witnessPose=pose;witness=centre;}
                }
            }
            bool proofHit=sampledHit&&minSdf< -1e-6,proofClear=!expandedHit&&minSdf>delta+rho+1e-6;
            string state=proofHit?"intersecting":proofClear?"clear":"uncertain-refine";
            checks.Add(new{id,state,sampledBackendHit=sampledHit,expandedBackendHit=expandedHit,minimumSampledCentreSdfMM=minSdf,motionEnvelopeMM=delta,fixtureCellRadiusMM=rho,nativePoseDeviationBoundMM=maxNativeError,numericEnvelopePaddingMM=.001,witness=new{centreMM=witness.Array(),tipMM=witnessPose.Tip.Array(),axisTowardSpindle=witnessPose.Axis.Array(),segment=witnessPose.Segment,index=witnessPose.Index},meaning=state=="clear"?"continuous canonical trajectory avoids the complete explicit fixture box":state=="intersecting"?"fixture interior centre lies inside the holder at an actual canonical sample":"no clearance certificate; sub-voxel or between-sample intersection remains possible"});
        }
        Digests();string pending=output+".pending-"+Guid.NewGuid().ToString("N");Directory.CreateDirectory(pending);var artifacts=new List<object>();
        foreach(var pair in meshes){Check();string path=Path.Combine(pending,"fixture-"+pair.Item1+".stl");StlExporter.Export(pair.Item2,path);artifacts.Add(new{path=Path.GetFileName(path),bytes=new FileInfo(path).Length,sha256=Hash(path)});}
        var report=new{schema="floe.holder-fixture-result.v1",status="computed-component-not-job-accepted",productReady=false,fullE38Accepted=false,motionInputSHA256=a[4],motionManifestSHA256=a[5],fixturesInputSHA256=a[6],sourceReference=r.GetProperty("sourceReference").Clone(),backend=new{coreSHA256=Core,hostSHA256=Hash(typeof(FixtureClearanceHost).Assembly.Location)},holder=holder.Clone(),evaluatedPoses=samples.Count,checks,artifacts,scope="one explicit axisymmetric cylindrical noncutting part versus static full AABB fixtures; no joints, IK, machine body, target gouge, holder assembly, cutting force or machine safety certification"};
        File.WriteAllText(Path.Combine(pending,"manifest.json"),JsonSerializer.Serialize(report,new JsonSerializerOptions{WriteIndented=true}));Check();Digests();Directory.Move(pending,output);Console.WriteLine(JsonSerializer.Serialize(new{status=report.status,manifestSHA256=Hash(Path.Combine(output,"manifest.json")),checks}));return 0;
    }
}
