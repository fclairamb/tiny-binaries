use std::io::{self, Write};
use std::net::{Ipv4Addr, TcpStream};
use std::process::exit;

fn fail(msg: &str) -> ! {
    // Not eprintln!: it panics when stderr is a broken pipe, and the exit status must stay 1.
    let _ = writeln!(io::stderr(), "{msg}");
    exit(1)
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        fail("usage: tcp <ipv4> <port>");
    }
    let ip: Ipv4Addr = args[1].parse().unwrap_or_else(|_| fail("bad address"));
    let port: u16 = args[2].parse().unwrap_or_else(|_| fail("bad port"));
    let mut stream = TcpStream::connect((ip, port)).unwrap_or_else(|e| fail(&e.to_string()));
    stream.write_all(b"hello\n").unwrap_or_else(|e| fail(&e.to_string()));
    io::copy(&mut stream, &mut io::stdout()).unwrap_or_else(|e| fail(&e.to_string()));
}
