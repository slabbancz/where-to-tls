use std::{fs, process::Command};

fn main() {
    println!("cargo:rerun-if-changed=Cargo.lock");
    let output = Command::new("rustc")
        .arg("--version")
        .output()
        .expect("rustc --version must run");
    let version = String::from_utf8(output.stdout).expect("rustc version must be UTF-8");
    println!("cargo:rustc-env=RUSTC_VERSION={}", version.trim());
    println!(
        "cargo:rustc-env=RUSTLS_VERSION={}",
        locked_dependency_version("rustls")
    );
}

fn locked_dependency_version(name: &str) -> String {
    let lock = fs::read_to_string("Cargo.lock").expect("Cargo.lock must be readable");
    let expected_name = format!("\"{name}\"");
    for package in lock.split("[[package]]") {
        let package_name = package
            .lines()
            .find_map(|line| line.trim().strip_prefix("name = "))
            .map(str::trim);
        if package_name != Some(expected_name.as_str()) {
            continue;
        }
        return package
            .lines()
            .find_map(|line| line.trim().strip_prefix("version = "))
            .map(str::trim)
            .map(|version| version.trim_matches('"').to_owned())
            .expect("locked rustls package must have a version");
    }
    panic!("Cargo.lock must contain the rustls package");
}
