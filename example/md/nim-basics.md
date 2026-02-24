# Nim Basics

A quick introduction to Nim programming.

---

## Variables

```nim
let x = 10      # immutable
var y = 20      # mutable
const z = 30    # compile-time constant
```

## Procedures

```nim
proc greet(name: string): string =
  "Hello, " & name & "!"
```
