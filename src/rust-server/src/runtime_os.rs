use std::{fs, io, path::Path};

pub struct RuntimeOperatingSystem {
    pub name: String,
    pub source: String,
}

pub fn read(paths: &[&Path]) -> Result<RuntimeOperatingSystem, String> {
    for path in paths {
        let contents = match fs::read_to_string(path) {
            Ok(contents) => contents,
            Err(error) if error.kind() == io::ErrorKind::NotFound => continue,
            Err(error) => return Err(format!("read runtime OS evidence {}: {error}", path.display())),
        };
        return Ok(RuntimeOperatingSystem {
            name: contents,
            source: path.to_string_lossy().into_owned(),
        });
    }
    Ok(RuntimeOperatingSystem {
        name: "unexposed-by-runtime".into(),
        source: "unexposed-by-runtime".into(),
    })
}
