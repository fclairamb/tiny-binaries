// Links the bins with holes.ld. Cargo does not track linker scripts, so without the
// rerun-if-changed line an edit to holes.ld would be ignored by a warm target dir.
fn main() {
    let dir = std::env::var("CARGO_MANIFEST_DIR").unwrap();
    println!("cargo:rerun-if-changed=holes.ld");
    println!("cargo:rustc-link-arg-bins=-T{dir}/holes.ld");
}
