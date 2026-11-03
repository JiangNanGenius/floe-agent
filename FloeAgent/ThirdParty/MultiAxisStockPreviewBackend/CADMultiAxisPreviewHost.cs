// SPDX-License-Identifier: MPL-2.0
// Domain adapter for existing jobs.submit -> exec.shell, not an execution tool.
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Numerics;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;
public static class CADMultiAxisPreviewHost {
    const string Core="3405064ebc312dbe38bacfdfb0eea8015354447ae3f749e4089cb8f584d1351d";
    static volatile bool cancelled;
    static void Check(){if(cancelled)throw new OperationCanceledException();}
    static void Keys(JsonElement e,params string[] keys){if(e.ValueKind!=JsonValueKind.Object||e.EnumerateObject().Any(x=>!keys.Contains(x.Name)))throw new ArgumentException("unsupported fields; no machine-joint, turn-mill or target override is accepted");}
    static string Hash(string p)=>Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(p))).ToLowerInvariant();
    static string Safe(string root,string relative){
        if(Path.IsPathRooted(relative)||relative.Split('/').Any(x=>x==".."||x==""))throw new ArgumentException("safe relative member required");
        string path=Path.GetFullPath(Path.Combine(root,relative));if(!path.StartsWith(root+Path.DirectorySeparatorChar,StringComparison.Ordinal))throw new ArgumentException("outside owned workspace");
        for(FileSystemInfo? p=new FileInfo(path);p!=null&&p.FullName!=root;p=p is DirectoryInfo d?d.Parent:((FileInfo)p).Directory)if(p.LinkTarget!=null)throw new ArgumentException("symlink member refused");
        return path;
    }
    static double[] Vec(JsonElement e){double[] a=e.EnumerateArray().Select(x=>x.GetDouble()).ToArray();if(a.Length!=3||a.Any(x=>!double.IsFinite(x)||Math.Abs(x)>100))throw new ArgumentException("finite XYZ within 100mm required");return a;}
    static (double[] Lo,double[] Hi) MeshBounds(string path){
        using var r=new BinaryReader(File.OpenRead(path));if(r.ReadUInt32()!=0x4F533344)throw new InvalidDataException("native mesh magic");uint version=r.ReadUInt32(),n=r.ReadUInt32(),indices=r.ReadUInt32();
        long stride=version==2?32:24;if((version!=1&&version!=2)||n<1||n>1000000||indices==0||indices%3!=0||indices>3000000||r.BaseStream.Length!=16+stride*n+4L*indices)throw new InvalidDataException("native mesh budget/layout");
        var lo=new[]{double.PositiveInfinity,double.PositiveInfinity,double.PositiveInfinity};var hi=new[]{double.NegativeInfinity,double.NegativeInfinity,double.NegativeInfinity};
        for(int i=0;i<n;i++)for(int axis=0;axis<3;axis++){float v=r.ReadSingle();if(!float.IsFinite(v)||Math.Abs(v)>100)throw new ArgumentException("selected part exceeds preview coordinate budget");lo[axis]=Math.Min(lo[axis],v);hi[axis]=Math.Max(hi[axis],v);}
        r.BaseStream.Position=16+stride*n;for(int i=0;i<indices;i++)if(r.ReadUInt32()>=n)throw new InvalidDataException("native mesh index");return(lo,hi);
    }
    // Refuse edge/corner-contact voxel unions; never label a nonmanifold mesh ready or repair it silently.
    static void RequireClosedBoundary(string path,double h){
        using var r=new BinaryReader(File.OpenRead(path));r.BaseStream.Position=80;uint n=r.ReadUInt32();
        if(n==0||n>400000||r.BaseStream.Length!=84+50L*n)throw new InvalidDataException("STL boundary budget: "+path);
        var edges=new Dictionary<((uint,uint,uint),(uint,uint,uint)),int>();
        var links=new Dictionary<(uint,uint,uint),List<((uint,uint,uint),(uint,uint,uint))>>();
        for(int i=0;i<n;i++){
            if(i%1024==0)Check();var normal=new Vector3(r.ReadSingle(),r.ReadSingle(),r.ReadSingle());
            var v=new Vector3[3];var keys=new (uint,uint,uint)[3];
            for(int j=0;j<3;j++){v[j]=new(r.ReadSingle(),r.ReadSingle(),r.ReadSingle());if(!float.IsFinite(v[j].X)||!float.IsFinite(v[j].Y)||!float.IsFinite(v[j].Z))throw new InvalidDataException("nonfinite STL");keys[j]=(BitConverter.SingleToUInt32Bits(v[j].X==0?0:v[j].X),BitConverter.SingleToUInt32Bits(v[j].Y==0?0:v[j].Y),BitConverter.SingleToUInt32Bits(v[j].Z==0?0:v[j].Z));}
            r.ReadUInt16();var cross=Vector3.Cross(v[1]-v[0],v[2]-v[0])/(float)(h*h);if(normal!=cross||normal.LengthSquared()!=1)throw new InvalidDataException("STL normals: "+path);
            for(int j=0;j<3;j++){var centre=keys[j];if(!links.TryGetValue(centre,out var list)){list=new();links[centre]=list;}list.Add((keys[(j+1)%3],keys[(j+2)%3]));var a=keys[j];var b=keys[(j+1)%3];if(Comparer<(uint,uint,uint)>.Default.Compare(a,b)>0)(a,b)=(b,a);var edge=(a,b);edges[edge]=edges.TryGetValue(edge,out int count)?count+1:1;}
        }
        int bad=edges.Values.Count(x=>x!=2);if(bad!=0)throw new InvalidDataException("nonmanifold voxel boundary ("+bad+" edges): "+path+"; change the path/resolution in a new operation; original output remains pending");
        foreach(var link in links.Values){
            Check();var adjacent=new Dictionary<(uint,uint,uint),HashSet<(uint,uint,uint)>>();
            foreach(var(a,b)in link){if(!adjacent.TryGetValue(a,out var aa)){aa=new();adjacent[a]=aa;}if(!adjacent.TryGetValue(b,out var bb)){bb=new();adjacent[b]=bb;}aa.Add(b);bb.Add(a);}
            var visited=new HashSet<(uint,uint,uint)>();var stack=new Stack<(uint,uint,uint)>();stack.Push(adjacent.Keys.First());while(stack.Count>0){var v=stack.Pop();if(visited.Add(v))foreach(var next in adjacent[v])stack.Push(next);}
            if(visited.Count!=adjacent.Count||adjacent.Values.Any(x=>x.Count!=2))throw new InvalidDataException("nonmanifold vertex link: "+path+"; original output remains pending");
        }
    }
    public static int Main(string[] args){try{return Run(args);}catch(Exception e){Console.Error.WriteLine(e);return e is OperationCanceledException?130:1;}}
    static int Run(string[] args){
        if(!RuntimeInformation.IsOSPlatform(OSPlatform.OSX)||RuntimeInformation.ProcessArchitecture!=Architecture.Arm64)throw new PlatformNotSupportedException("arm64 macOS managed target required; no host fallback");
        if(args.Length==3&&args[0]=="--promote-directory"){
            string from=Path.GetFullPath(args[1]),to=Path.GetFullPath(args[2]);if(Path.GetDirectoryName(from)!=Path.GetDirectoryName(to)||!Path.GetFileName(from).Contains(".pending-")||!Directory.Exists(from))throw new ArgumentException("promotion boundary");if(Directory.Exists(to))return 2;Directory.Move(from,to);return 0;
        }
        if(args.Length!=4)throw new ArgumentException("workspace input-relative output-relative expected-input-SHA256");
        Console.CancelKeyPress+=(_,e)=>{e.Cancel=true;cancelled=true;};
        string root=Path.GetFullPath(args[0]),input=Safe(root,args[1]),output=Safe(root,args[2]);
        if(Directory.Exists(output)||File.Exists(output))throw new IOException("old output preserved; use the existing owned job or a new operation");
        if(new FileInfo(input).Length>65536||Hash(input)!=args[3])throw new InvalidDataException("frozen request SHA/budget");
        if(Hash(typeof(MillSimSharp.Simulation.CutterSimulator).Assembly.Location)!=Core)throw new InvalidDataException("core pin");
        using var doc=JsonDocument.Parse(File.ReadAllBytes(input));var q=doc.RootElement;
        Keys(q,"schema","units","ownerBinding","source","parameters");
        if(q.GetProperty("schema").GetString()!="floe.cad-multi-axis-preview-task.v1"||q.GetProperty("units").GetString()!="mm")throw new ArgumentException("task schema/units");
        var owner=q.GetProperty("ownerBinding");foreach(string key in new[]{"operationID","conversationID","runID"})if(!Guid.TryParse(owner.GetProperty(key).GetString(),out _))throw new ArgumentException("owner ID");
        if(string.IsNullOrWhiteSpace(owner.GetProperty("environmentID").GetString())||owner.GetProperty("studyRevision").GetInt32()!=1)throw new ArgumentException("explicit environment/revision required");
        var source=q.GetProperty("source");var originals=new Dictionary<string,string>();
        foreach(var file in source.GetProperty("files").EnumerateArray()){
            string rel=file.GetProperty("path").GetString()!,path=Safe(root,rel),sha=file.GetProperty("sha256").GetString()!;
            if(new FileInfo(path).Length>16000000||Hash(path)!=sha)throw new InvalidDataException("source member changed");originals.Add(rel,sha);
        }
        if(originals.Count!=4)throw new InvalidDataException("exactly four frozen source members required");
        string snapshot=source.GetProperty("snapshotRoot").GetString()!;string model=Safe(root,snapshot+"/document.json"),manifest=Safe(root,snapshot+"/manifest.json");
        if(!originals.ContainsKey(snapshot+"/document.json")||!originals.ContainsKey(snapshot+"/manifest.json"))throw new InvalidDataException("source snapshot membership");
        using var md=JsonDocument.Parse(File.ReadAllBytes(model));using var mf=JsonDocument.Parse(File.ReadAllBytes(manifest));
        if(mf.RootElement.GetProperty("revision").GetInt64()!=source.GetProperty("documentRevision").GetInt64()||mf.RootElement.GetProperty("modelSHA256").GetString()!=source.GetProperty("modelSHA256").GetString()||mf.RootElement.GetProperty("unit").GetString()!="mm")throw new InvalidDataException("saved model identity");
        string bodyID=source.GetProperty("bodyID").GetString()!;var body=md.RootElement.GetProperty("bodies").EnumerateArray().Single(x=>string.Equals(x.GetProperty("bodyID").GetString(),bodyID,StringComparison.OrdinalIgnoreCase));
        using var transform=JsonDocument.Parse(Convert.FromBase64String(body.GetProperty("transform").GetString()!));var tr=transform.RootElement;
        if(!Vec(tr.GetProperty("translation")).SequenceEqual(new double[]{0,0,0})||tr.GetProperty("scale").GetDouble()!=1||!tr.GetProperty("rotation").EnumerateArray().Select(x=>x.GetDouble()).SequenceEqual(new double[]{0,0,0,1}))throw new ArgumentException("identity placement required");
        string meshRel=snapshot+"/"+body.GetProperty("meshBlob").GetString(),brepRel=snapshot+"/"+body.GetProperty("brepBlob").GetString();
        if(!originals.TryGetValue(meshRel,out var mh)||mh!=body.GetProperty("meshSHA256").GetString()||!originals.TryGetValue(brepRel,out var bh)||bh!=body.GetProperty("brepSHA256").GetString())throw new InvalidDataException("selected mesh/BRep identity");
        var nativeBounds=MeshBounds(Safe(root,meshRel));var p=q.GetProperty("parameters");Keys(p,"mode","resolutionMM","radiusMM","lengthMM","sampling","poses","holder","fixtures");if(p.GetProperty("mode").GetString()!="multi-axis-preview")throw new ArgumentException("multi-axis-preview mode required");double h=p.GetProperty("resolutionMM").GetDouble();if(!new[]{.25,.5,1.0}.Contains(h))throw new ArgumentException("preview resolution");
        // Explicit outward rounding contains the selected native mesh. The part itself is reference-only.
        double[] lo=nativeBounds.Lo.Select(x=>Math.Floor(x/h)*h).ToArray(),hi=nativeBounds.Hi.Select(x=>Math.Ceiling(x/h)*h).ToArray();
        string pending=output+".pending-"+Guid.NewGuid().ToString("N");Directory.CreateDirectory(pending);
        string motionInput=Path.Combine(pending,"motion-input.json");
        var motion=new{schema="floe.multi-axis-stock.v1",units="mm",qualificationID=owner.GetProperty("operationID").GetString(),sourceReference=new{kind="frozen-native-CAD-snapshot",source=source.Clone(),ownerBinding=owner.Clone(),ownerBindingVerified=false},stock=new{minMM=lo,maxMM=hi,resolutionMM=h},tool=new{kind="flat-end-mill",radiusMM=p.GetProperty("radiusMM").GetDouble(),lengthMM=p.GetProperty("lengthMM").GetDouble()},sampling=p.GetProperty("sampling").Clone(),poses=p.GetProperty("poses").Clone()};
        File.WriteAllText(motionInput,JsonSerializer.Serialize(motion));Check();
        int stockCode=MultiAxisStockHost.Main(new[]{motionInput,Path.Combine(pending,"motion"),Hash(motionInput)});Check();if(stockCode!=0)throw new InvalidDataException("multi-axis stock computation failed; pending evidence preserved");
        foreach(string stem in new[]{"nominal","remaining-lower","remaining-upper"})RequireClosedBoundary(Path.Combine(pending,"motion",stem+".stl"),h);
        Check();bool hasFixtures=p.GetProperty("fixtures").GetArrayLength()>0;
        if(hasFixtures){string fi=Path.Combine(pending,"fixtures-input.json");var request=new{schema="floe.holder-fixture.v1",units="mm",holder=p.GetProperty("holder").Clone(),fixtures=p.GetProperty("fixtures").Clone()};File.WriteAllText(fi,JsonSerializer.Serialize(request));int fixtureCode=FixtureClearanceHost.Main(new[]{motionInput,Path.Combine(pending,"motion"),fi,Path.Combine(pending,"fixtures"),Hash(motionInput),Hash(Path.Combine(pending,"motion/manifest.json")),Hash(fi)});Check();if(fixtureCode!=0)throw new InvalidDataException("holder checks failed; pending evidence preserved");foreach(var fixture in p.GetProperty("fixtures").EnumerateArray())RequireClosedBoundary(Path.Combine(pending,"fixtures","fixture-"+fixture.GetProperty("id").GetString()+".stl"),fixture.GetProperty("resolutionMM").GetDouble());}
        Check();foreach(var member in originals)if(Hash(Safe(root,member.Key))!=member.Value)throw new IOException("native source changed during computation");if(Hash(input)!=args[3])throw new IOException("request changed during computation");
        File.Copy(Path.Combine(pending,"motion/nominal.stl"),Path.Combine(pending,"stock.stl"));File.Copy(Path.Combine(pending,"motion/nominal.occupancy"),Path.Combine(pending,"stock.occupancy"));
        using var cm=JsonDocument.Parse(File.ReadAllBytes(Path.Combine(pending,"motion/manifest.json")));var material=cm.RootElement.GetProperty("material");
        var artifacts=Directory.GetFiles(pending,"*",SearchOption.AllDirectories).Select(x=>new{path=Path.GetRelativePath(pending,x).Replace('\\','/'),bytes=new FileInfo(x).Length,sha256=Hash(x)}).OrderBy(x=>x.path,StringComparer.Ordinal).ToArray();
        var result=new{schema="floe.cad-multi-axis-preview-result.v1",outcome="computed-not-job-accepted",fullE38Accepted=false,requestSHA256=args[3],ownerBinding=owner.Clone(),ownerBindingVerified=false,source=source.Clone(),sourceUnchanged=true,
            backend=new{sourcePin="3cdd4f54ef94e6b95f2a149dad246b4e73aad4e9",coreSHA256=Core,wrapperSHA256=Hash(typeof(CADMultiAxisPreviewHost).Assembly.Location),motionHostSHA256=Hash(typeof(MultiAxisStockHost).Assembly.Location),fixtureHostSHA256=Hash(typeof(FixtureClearanceHost).Assembly.Location),actualOS=RuntimeInformation.OSDescription,architecture=RuntimeInformation.ProcessArchitecture.ToString(),runtime=Environment.Version.ToString()},
            stock=new{mode="outward-rounded-part-bounds-blank",partIsReferenceOnly=true,resolutionMM=h,boundsMin=lo,boundsMax=hi,nativeBoundsMin=nativeBounds.Lo,nativeBoundsMax=nativeBounds.Hi,removedMM3=material.GetProperty("nominalRemovedMM3").GetDouble(),remainingMM3=material.GetProperty("nominalRemainingMM3").GetDouble(),continuousRemainingLowerMM3=material.GetProperty("continuousRemainingLowerMM3").GetDouble(),continuousRemainingUpperMM3=material.GetProperty("continuousRemainingUpperMM3").GetDouble()},
            precision="Bounded XYZ+IJK voxel stock preview with continuous-volume bracket; sampled nominal, cylindrical holder/box fixtures only. No CAM planner, turn-mill, machine joints/IK, target gouge or complete machine safety.",artifacts};
        File.WriteAllText(Path.Combine(pending,"manifest.json"),JsonSerializer.Serialize(result,new JsonSerializerOptions{WriteIndented=true}));Check();foreach(var member in originals)if(Hash(Safe(root,member.Key))!=member.Value)throw new IOException("source changed before output commit");if(Hash(input)!=args[3])throw new IOException("request changed before output commit");Directory.Move(pending,output);
        Console.WriteLine(JsonSerializer.Serialize(new{outcome=result.outcome,manifestSHA256=Hash(Path.Combine(output,"manifest.json")),result.stock}));return 0;
    }
}
