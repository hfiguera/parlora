fn main() {
    let library = pkg_config::Config::new()
        .exactly_version("1.6.1")
        .statik(false)
        .probe("opus")
        .expect("Parlora browser audio requires system libopus 1.6.1 via pkg-config");
    println!("cargo:warning=Using system libopus {}", library.version);
}
