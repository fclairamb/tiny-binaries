import net
import os

fn main() {
	if os.args.len < 3 {
		eprintln('usage: tcp <ipv4> <port>')
		exit(1)
	}
	mut conn := net.dial_tcp('${os.args[1]}:${os.args[2]}') or {
		eprintln(err)
		exit(1)
	}
	defer {
		conn.close() or {}
	}
	conn.write_string('hello\n') or {
		eprintln(err)
		exit(1)
	}
	mut stdout := os.stdout()
	mut buf := []u8{len: 4096}
	for {
		n := conn.read(mut buf) or { break }
		if n <= 0 {
			break
		}
		stdout.write(buf[..n]) or {
			eprintln(err)
			exit(1)
		}
	}
}
