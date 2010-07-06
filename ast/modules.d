module ast.modules;

import ast.base, ast.namespace, ast.fun, ast.variable, ast.structure, ast.parse;

import tools.ctfe, tools.base: startsWith;

class Module : Namespace, Tree, Named {
  string name;
  Module[] imports;
  Tree[] entries;
  mixin defaultIterate!(imports, entries);
  override {
    string getIdentifier() { return name; }
    void emitAsm(AsmFile af) {
      foreach (entry; entries)
        entry.emitAsm(af);
    }
    string mangle(string name, IType type) {
      return "module_"~this.name~"_"~name~"_of_"~type.mangle();
    }
    Object lookup(string name, bool local = false) {
      if (auto res = super.lookup(name)) return res;
      if (auto lname = name.startsWith(this.name~"."))
        if (auto res = super.lookup(lname)) return res;
      
      foreach (mod; imports)
        if (auto res = mod.lookup(name)) return res;
      return null;
    }
  }
  override Stuple!(IType, string, int)[] stackframe() { assert(false); }
}

Module sysmod;

Module lookupMod(string name) {
  if (name == "sys") {
    return sysmod;
  }
  assert(false, "TODO");
}

import ast.pointer;
// not static this() to work around a precedence bug in phobos. called from fcc.
void setupSysmods() {
  New(sysmod);
  sysmod.name = "sys";
  {
    auto puts = new Function;
    puts.extern_c = true;
    New(puts.type);
    puts.type.ret = Single!(Void);
    puts.type.params ~= stuple(cast(IType) Single!(Pointer, Single!(Char)), cast(string) null);
    puts.name = "puts";
    sysmod.add(puts);
  }
  
  {
    auto printf = new Function;
    printf.extern_c = true;
    New(printf.type);
    printf.type.ret = Single!(Void);
    printf.type.params ~= stuple(cast(IType) Single!(Pointer, Single!(Char)), cast(string) null);
    printf.type.params ~= stuple(cast(IType) Single!(Variadic), cast(string) null);
    printf.name = "printf";
    sysmod.add(printf);
  }
}

Object gotExtern(ref string text, ParseCb cont, ParseCb rest) {
  auto t2 = text;
  if (!t2.accept("extern(C)")) return null;
  auto fun = new Function;
  fun.extern_c = true;
  New(fun.type);
  if (test(fun.type.ret = cast(IType) rest(t2, "type")) &&
      t2.gotIdentifier(fun.name) &&
      t2.gotParlist(fun.type.params, rest) &&
      t2.accept(";")
    )
  {
    text = t2;
    namespace().add(fun);
    return Single!(NoOp);
  } else assert(false);
}
mixin DefaultParser!(gotExtern, "tree.toplevel.extern_c");

Object gotImport(ref string text, ParseCb cont, ParseCb rest) {
  string m;
  // import a, b, c;
  if (!text.accept("import ")) return null;
  auto mod = namespace().get!(Module);
  if (!(
    text.bjoin(text.gotIdentifier(m, true), text.accept(","),
    { mod.imports ~= lookupMod(m); },
    true) &&
    text.accept(";")
  )) throw new Exception("Unexpected text while parsing import statement: "~text.next_text());
  return Single!(NoOp);
}
mixin DefaultParser!(gotImport, "tree.import");

Object gotModule(ref string text, ParseCb cont, ParseCb restart) {
  auto t2 = text;
  Function fn;
  Structure st;
  Tree tr;
  Module mod;
  auto backup = namespace.ptr();
  scope(exit) namespace.set(backup);
  if (t2.accept("module ") && (New(mod), namespace.set(mod), true) &&
      t2.gotIdentifier(mod.name, true) && t2.accept(";") &&
      t2.many(
        !!restart(t2, "tree.toplevel", &tr),
        { mod.entries ~= tr; }
      ) &&
      (text = t2, true)
    ) return mod;
  else return null;
}
mixin DefaultParser!(gotModule, "tree.module");
