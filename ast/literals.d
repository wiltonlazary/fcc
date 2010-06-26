module ast.literals;

import ast.base, ast.pointer, tools.base: slice, replace, startsWith;

public import ast.int_literal;

import ast.static_arrays, parseBase;

class StringExpr : CValue, Setupable {
  string str;
  this() { }
  this(string s) { str = s; }
  mixin defaultIterate!();
  string name_used;
  // default action: place in string segment, load address on stack
  override void setup(AsmFile af) {
    name_used = Format("cons_", af.constants.length);
    af.constants[name_used] = cast(ubyte[]) str;
  }
  override void emitAsm(AsmFile af) {
    assert(false, "Why are you pushing a string on the stack? This seems iffy to me. ");
  }
  override void emitLocation(AsmFile af) {
    af.pushStack("$"~name_used, Single!(Pointer, Single!(Char)));
  }
  override Type valueType() { return new StaticArray(Single!(Char), str.length); }
}

bool gotStringExpr(ref string text, out Expr ex) {
  auto t2 = text;
  StringExpr se;
  return t2.accept("\"") &&
    (se = new StringExpr, true) &&
    (se.str = t2.slice("\"").replace("\\n", "\n"), true) &&
    (text = t2, true) &&
    (ex = se, true);
}

Object gotLiteralExpr(ref string text, ParseCb cont, ParseCb rest) {
  Expr ex;
  if (text.gotStringExpr(ex) || text.gotIntExpr(ex)) return cast(Object) ex;
  else return null;
}
mixin DefaultParser!(gotLiteralExpr, "tree.expr.literal", "5");

/// "foo": char[3] -> char*
class CValueAsPointer : Expr {
  CValue sup;
  mixin This!("sup");
  mixin defaultIterate!(sup);
  override Type valueType() {
    if (auto sa = cast(StaticArray) sup.valueType())
      return new Pointer(sa.elemType);
    throw new Exception(Format("The CValue ", sup, " has confused me. "));
  }
  override void emitAsm(AsmFile af) {
    if (auto s = cast(Setupable) sup)
      s.setup(af);
    sup.emitLocation(af);
  }
}

Object gotCValueAsPointer(ref string st, ParseCb cont, ParseCb rest) {
  CValue cv;
  if (!rest(st, "tree.expr ^selfrule", &cv))
    return null;
  return new CValueAsPointer(cv);
}
mixin DefaultParser!(gotCValueAsPointer, "tree.expr.cv_as_ptr", "908");
