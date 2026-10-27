# ZLOX

[craftinginterpreters](https://craftinginterpreters.com/) 的 Zig 实现

- [A Tree-Walk Interpreter](./src/treewalk)
- [Virtual Machine](./src/vm)

```sh
zig build run                    # treewalk REPL
zig build run -- path/to/script.lox
zig build run-vm                 # VM REPL
zig build run-vm -Dtrace-execution -Dprint-code
```

```sh
cat<<'EOF' > /tmp/zlox-example.lox
fun fib(n) {
    if (n == 1 or n == 2) {
        return 1;
    }

    return fib(n-1) + fib(n-2);
}

for (var i = 1; i <= 6; i = i + 1) {
    print fib(i);
}
EOF
zig build run -- /tmp/zlox-example.lox
```

输出 `1 1 2 3 5 8`。
