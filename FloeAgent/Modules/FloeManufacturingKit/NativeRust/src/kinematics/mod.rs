// Original OpenMill kinematics modules at the pinned upstream commit
// charlatanshost/OpenMill@0432a8c540d1187dc6cb9383ce1b4f2dd97287f6
// (openmill-core/src/kinematics/{types,traits,table_table,default_machines}.rs),
// carried byte-identical under the upstream MIT license option
// (see ../upstream/LICENSE-MIT copied alongside).
// Floe-side physical gauge/travel/conditioning adapter: ../ac.rs.
#[path = "../../upstream/types.rs"]
pub mod types;
#[path = "../../upstream/traits.rs"]
pub mod traits;
#[path = "../../upstream/table_table.rs"]
pub mod table_table;
#[path = "../../upstream/default_machines.rs"]
pub mod default_machines;
pub use table_table::TableTable;
pub use traits::{ForwardKinematics, InverseKinematics};
