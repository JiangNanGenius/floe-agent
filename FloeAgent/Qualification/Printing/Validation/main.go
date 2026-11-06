// SPDX-License-Identifier: MPL-2.0
// Qualification only. Independent MIT uv3dp decoder; never links Kiri's reader/encoder.
package main
import("os";"fmt";"encoding/json";"image/png";"path/filepath";"crypto/sha256";"github.com/ezrec/uv3dp/ctb")
func main(){
 if len(os.Args)!=3{panic("usage: ctb-validate input.ctb output-directory")}
 f,err:=os.Open(os.Args[1]);if err!=nil{panic(err)};defer f.Close();st,err:=f.Stat();if err!=nil{panic(err)}
 p,err:=ctb.NewFormatter(".ctb").Decode(f,st.Size());if err!=nil{panic(err)}
 size:=p.Size();out:=os.Args[2];if err=os.MkdirAll(out,0755);err!=nil{panic(err)}
 layers:=[]any{};volume:=float64(0)
 for i:=0;i<size.Layers;i++{
  im:=p.LayerImage(i);count:=0;minx,miny,maxx,maxy:=im.Bounds().Max.X,im.Bounds().Max.Y,-1,-1
  for y:=0;y<im.Bounds().Max.Y;y++{for x:=0;x<im.Bounds().Max.X;x++{if im.GrayAt(x,y).Y>0{count++;if x<minx{minx=x};if x>maxx{maxx=x};if y<miny{miny=y};if y>maxy{maxy=y}}}}
  if count==0{panic(fmt.Sprintf("empty layer %d",i))}
  volume+=float64(count)*float64(size.Millimeter.X)*float64(size.Millimeter.Y)/float64(size.X*size.Y)*float64(size.LayerHeight)
  h:=sha256.Sum256(im.Pix)
  layers=append(layers,map[string]any{"index":i,"z":p.LayerZ(i),"exposure":p.LayerExposure(i),"litPixels":count,"pixelBounds":[]int{minx,miny,maxx,maxy},"pixelSHA256":fmt.Sprintf("%x",h)})
  if i==0||i==size.Layers/2||i==size.Layers-1{dst,err:=os.Create(filepath.Join(out,fmt.Sprintf("layer-%03d.png",i)));if err!=nil{panic(err)};if err=png.Encode(dst,im);err!=nil{panic(err)};dst.Close()}
 }
 report:=map[string]any{"decoder":"github.com/ezrec/uv3dp v1.2.12 (MIT), qualification only","size":size,"exposure":p.Exposure(),"bottom":p.Bottom(),"layers":layers,"computedVolumeMM3":volume}
 b,_:=json.MarshalIndent(report,"","  ");if err=os.WriteFile(filepath.Join(out,"readback.json"),b,0644);err!=nil{panic(err)}
 fmt.Printf("independent CTB decode: %d layers, %dx%d, %.3f mm3\n",size.Layers,size.X,size.Y,volume)
}
