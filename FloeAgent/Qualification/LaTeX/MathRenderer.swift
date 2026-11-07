import UIKit
import SwiftMath

@MainActor enum QualificationMathRenderer {
    static func image(_ source:String,size:CGFloat)->UIImage? {
        guard source.utf8.count<=8192 else{return nil}
        var depth=0
        for character in source {if character=="{" {depth+=1};if character=="}" {depth-=1};if depth<0 || depth>64 {return nil}}
        guard depth==0 else{return nil}
        // The image API applies the Core Text coordinate transform explicitly.
        // Rendering a flipped UILabel layer mirrored glyphs and superscripts.
        var formula=MathImage(latex:source,fontSize:size,textColor:.label)
        let (error,image,_)=formula.asImage()
        guard error == nil,let image,image.size.width>0,image.size.height>0,image.size.width<1600,image.size.height<800 else{return nil}
        return image
    }
}
