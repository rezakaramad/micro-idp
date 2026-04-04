# Deep-dive

At this point in time, it is hard for me to quickly figure out Go syntax.

Therefore, I am going to deep dive a bit to gain more knowledge and get myself up to speed.

Let’s look at this line:

```go
ctx := kong.Parse(cli, kong.Description("A Crossplane Composition Function."))
```
The hard part is that this line only makes sense if you already know what a command-line program is supposed to do at startup.

## First: what problem is this solving?

When a program starts, it often needs settings.
For example, someone might run it like this:
```
my-function --insecure --address=:9443 -d
```

Those extra pieces:
- `--insecure`
- `--address=:9443`
- `-d`
are command-line arguments.

They are startup settings given to the program.

So before the program can do real work, it needs to:
- read those arguments
- understand what they mean
- store them somewhere usable

That is what `kong.Parse(...)` is for.

## What “CLI” means here
CLI means Command-Line Interface.
That just means:
> “This program can be configured or controlled by text arguments when you start it in the terminal.”

So this struct:
```
type CLI struct {
	Debug bool
	Network string
	Address string
	TLSCertsDir string
	Insecure bool
	MaxRecvMessageSize int
}
```

is basically a list of startup options the program supports.

So when it's said CLI config, it means:
> the set of command-line settings for this program

For this program, that includes things like:
- debug mode
- network
- address
- insecure mode
- max receive size

I have been struggling with the concept of CLI here, because CLI is something I normally associate with interaction between users and an API. I asked myself who is using the CLI and who is setting the options to parse later.

Here, CLI does not mean “interactive tool for end users.” It just means startup options for the binary.

## Why do we need to “parse” anything?

Because command-line arguments start out as just raw text.

For example, the shell may give the program something like:

```
["--insecure", "--address=:9443", "-d"]
```

That is just text.

The program still has to figure out:
- `--insecure` means `Insecure = true`
- `--address=:9443` means `Address = ":9443"`
- `-d` means `Debug = true`

That conversion step is what parse means here.

So:
> parse = read raw input text and turn it into structured values

## So what is `kong.Parse(...)`?

`kong` is a library.

Its job is to help with command-line arguments.

So `kong.Parse(...)` means something like:

> “Kong, please read the command-line arguments, match them to my CLI struct, fill in the values, and prepare the program to run.”

That is all.

It is a startup helper.

## What is `cli` in this context?

Here cli is typically something like:
```
cli := &CLI{}
```

That means:
> create an empty CLI struct and hand it to Kong

So before parsing, `cli` is just an empty container for settings.

After parsing, `cli` gets filled with values.

Example:

before parsing:
```
cli := &CLI{}
```

conceptually:
```
Debug = false
Network = ""
Address = ""
Insecure = false
...
```

after parsing, it might become:
```
Debug = true
Network = "tcp"
Address = ":9443"
Insecure = true
...
```
based on command-line arguments and defaults.

## What does `kong.Description("A Crossplane Composition Function.")` mean?

This is just extra metadata for the CLI tool.

It is not part of the business logic.

It is basically saying:

> “When showing help text for this command-line program, display this description.”

For example, if a user runs help, the tool may show something like:

```
A Crossplane Composition Function.
```

So this part:
```
kong.Description("A Crossplane Composition Function.")
```

is just a label/description for humans.

## The shortest definitions
### CLI
Command-line interface.
The way a user passes settings when starting the program.

### CLI config

The actual startup settings, stored in your CLI struct.

### parse

Read raw text input and turn it into structured values.

### `kong.Parse(...)`

Use the Kong library to read command-line arguments and fill the CLI struct.

### `kong.Description(...)`

A help/description string for humans using the command-line tool.

## One small thing that may make it click

This line is not about Crossplane logic.

It is not about reconciliation.
It is not about Kubernetes resources.

It is only about:

> how the program starts and reads its startup options

That is why it feels disconnected from the main function logic.

Because it is just bootstrapping.

## Crossplane Function Flow (Mental Model)
Let's see how a Crossplane Composition Function works:

```text
XR (TenantRequest)
   ↓
Composition (Pipeline)
   ↓
Crossplane
   ↓
calls your function with req
   ↓
your function modifies desired (the plan)
   ↓
returns rsp
   ↓
Crossplane stores desired + applies it (creates/updates resources)
   ↓
next run → sends updated observed + desired again
```

### Key Concepts

#### XR (Composite Resource)
- The user input (e.g. `TenantRequest`)
- Contains `spec` and `status`
- Drives the whole process

#### Composition (Pipeline Mode)
```
mode: Pipeline
pipeline:
  - step: render
    functionRef:
      name: function-tenantrequest
```

- Defines which function runs
- Acts as the execution pipeline
- Connects XR → Function

#### Function
- Your Go code (`RunFunction`)
- Reads input (req)
- Builds output (rsp)
- Decides what should exist

#### req (Request from Crossplane)
```
req
├── observed  (what exists in cluster)
├── desired   (plan so far)
└── meta      (execution info)
```

#### observed vs desired
observed = reality (actual cluster state)
desired  = plan    (what should exist)

### Reconciliation Loop
**First Run**

```
observed = {}
desired  = {}
```

Function:

```
desired["tenant-xr"] = Tenant
```

Crossplane applies:
Creates Tenant resource in cluster

**Second Run**
```
observed = { tenant-xr exists }
desired  = { tenant-xr }
```

Function:
- Checks if Tenant is ready
- Updates status/phase

**Third Run**
```
observed = { tenant-xr ready }
desired  = { tenant-xr }
```

Function:
Moves to Ready

**Key Insight**
> The function does NOT create resources directly —
> it declares desired state, and Crossplane makes it real.

**Mental Model**

```
User → XR
      ↓
Composition
      ↓
Function
      ↓
desired (plan)
      ↓
Crossplane
      ↓
cluster (observed)
      ↓
loop
```
