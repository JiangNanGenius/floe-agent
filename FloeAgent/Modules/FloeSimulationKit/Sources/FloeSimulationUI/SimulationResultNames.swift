import FloeSimulationCore

extension SimulationResultField {
    public var simulationDisplayName: String {
        let names: (String,String)? = switch id {
        case "potential": ("Electric potential","电势")
        case "electric_field": ("Electric field","电场")
        case "electric_flux": ("Electric displacement","电位移")
        case "electric_energy": ("Electric energy","电场能量")
        case "effective_capacitance": ("Energy-equivalent capacitance","能量等效电容")
        case "pressure": ("Pressure","声压")
        case "particle_velocity": ("Particle velocity","质点速度")
        case "sound_pressure_level": ("Sound pressure level","声压级")
        case "displacement": ("Displacement","位移")
        case "mode_shape": ("Normalized mode shape","归一化振型")
        case "modal_mass": ("Generalized modal mass","广义模态质量")
        case "modal_stiffness": ("Generalized modal stiffness","广义模态刚度")
        case "stress": ("Stress","应力")
        case "strain": ("Strain","应变")
        case "thermoelastic_stress": ("Mean thermoelastic stress","平均热弹性应力")
        case "von_mises_mean_stress": ("Von Mises of mean stress","平均应力的等效值")
        case "total_strain": ("Total strain","总应变")
        case "thermal_strain": ("Mean thermal strain","平均热应变")
        case "elastic_strain": ("Mean elastic strain","平均弹性应变")
        case "von_mises": ("Von Mises stress","等效应力")
        case "reaction": ("Reaction","支反力")
        case "temperature": ("Temperature","温度")
        case "boundary_heat_flow": ("Boundary heat flow","边界热流")
        case "body_position": ("Position","位置")
        case "body_rotation": ("Rotation","旋转")
        case "body_visible": ("Visible","可见性")
        case "body_velocity": ("Velocity","速度")
        case "body_angular_velocity": ("Angular velocity","角速度")
        default: id.hasPrefix("soft/") ? ("Soft body vertices","软体顶点") : nil
        }
        return names.map { simulationText($0.0,$0.1) } ?? name
    }
}
