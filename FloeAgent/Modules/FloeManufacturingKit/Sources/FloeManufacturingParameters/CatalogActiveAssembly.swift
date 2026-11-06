// SPDX-License-Identifier: MPL-2.0
import Foundation

extension ManufacturingParameterCatalog {
    static let groupActiveAssembly = ManufacturingParameterGroup(id:"activeAssembly",nameZH:"当前动力刀具总成",nameEN:"Active live-tool assembly")
    static let activeAssemblyParameters:[ManufacturingParameterDescriptor] = [
        P.d("millingAssembly.shankDiameterMM","activeAssembly","刀杆直径","Shank diameter",
            "当前动力刀具的刀杆直径。未设置总成时仅保存；切削刃长仍在动力刀具参数中。",
            "Shank diameter of the active live tool. Stored only until an assembly is configured; cutting-edge length remains in milling settings.",
            unit:.mm,kind:.number,min:0,max:1000,binding:"millingAssembly.shankDiameterMM",support:.previewUsed,
            reasonZH:"启用总成后参与刀杆与夹具、剩余材料检查。",reasonEN:"Used for shank queries against fixtures and remaining stock when the assembly is enabled.",
            refs:["OpenMill0432a8c:tool.rs:Tool.shank_diameter","r2/CONTRACT.md:millingAssembly"]),
        P.d("millingAssembly.holderProfile","activeAssembly","有效刀柄外形","Active holder profile",
            "每点为[距刀尖的轴向距离,半径]，单位mm；正方向朝主轴，同一轴向位置可表示肩台。这不同于未经转换的厂商量规原点记录。",
            "Each point is [axial distance from tool tip, radius] in mm, positive toward the spindle; equal axial coordinates describe shoulders. This is distinct from an unconverted vendor gauge-origin record.",
            kind:.array,binding:"millingAssembly.holderProfile",support:.previewUsed,
            reasonZH:"启用总成后用于刀柄外形查询；锥段近似和未决情况在结果中说明。",reasonEN:"Used for holder queries when the assembly is enabled; tapered approximation and unresolved queries are disclosed in results.",
            refs:["OpenMill0432a8c:tool.rs:ToolHolder.radius_at","r2/CONTRACT.md:tip-origin profile"]),
        P.d("millingAssembly.clearanceMM","activeAssembly","所需间隙","Required clearance",
            "要求切削部分与夹具、非切削部分与夹具及剩余材料保留的间隙。数值由实际工艺设定，不是推荐安全间隙。",
            "Required clearance between cutting parts and fixtures, and between non-cutting parts and fixtures/stock. Set for the actual process; this is not a recommended safety margin.",
            unit:.mm,kind:.number,min:0,max:100,binding:"millingAssembly.clearanceMM",support:.previewUsed,
            reasonZH:"启用总成后区分实体相交、间隙不足和查询未决。",reasonEN:"Distinguishes intersection, insufficient clearance and unresolved queries when the assembly is enabled.",
            refs:["Parry3d0.17.6:query::contact","r2/CONTRACT.md:clearance"]),
        P.d("budget.maxCollisionQueries","activeAssembly","碰撞查询预算","Collision query budget",
            "铣削与A/C碰撞的实际原生调用预算，缺省500000；耗尽会明确停止计算，不跳过部件。",
            "Budget for actual native milling and A/C collision-query calls, default500000. Exhaustion stops calculation explicitly rather than skipping components.",
            kind:.integer,def:.integer(500000),min:1,max:500000,binding:"budget.maxCollisionQueries",support:.previewUsed,
            reasonZH:"当前任务的铣削与A/C碰撞查询共用此预算，无总成时也适用于切削部分。",reasonEN:"Milling and A/C collision queries share this budget, including cutting-part queries when no assembly is configured.",
            refs:["r2/CONTRACT.md:query budget"]),
        P.d("activeAssembly.vendorExtensions","activeAssembly","厂商及其他总成参数","Vendor and other assembly parameters",
            "保存未单列的厂商字段。这里的扩展记录不会自动改变当前碰撞外形。",
            "Keep vendor fields not listed separately. Extension records do not automatically change the active collision envelope.",
            kind:.object,support:.configurationOnly,reasonZH:P.cfgReasonZH,reasonEN:P.cfgReasonEN,rare:true,
            refs:["task-required metadata gap","r2/CONTRACT.md:explicit active geometry"])
    ]
}
