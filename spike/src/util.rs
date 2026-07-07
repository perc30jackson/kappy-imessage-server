pub fn encode_hex(bytes: &[u8]) -> String {
    use std::fmt::Write;
    let mut s = String::with_capacity(bytes.len() * 2);
    for &b in bytes {
        write!(&mut s, "{b:02x}").unwrap();
    }
    s
}

pub fn plist_to_string<T: serde::Serialize>(value: &T) -> Result<String, plist::Error> {
    let mut buf = Vec::new();
    plist::to_writer_xml(std::io::Cursor::new(&mut buf), value)?;
    Ok(String::from_utf8(buf).unwrap())
}
