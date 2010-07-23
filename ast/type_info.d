module ast.type_of;

import ast.types, ast.base, ast.parse, ast.int_literal, ast.literals;

Object gotTypeof(ref string text, ParseCb cont, ParseCb rest) {
  auto t2 = text;
  Expr ex;
  if (!(
    t2.accept("typeof(") &&
    rest(t2, "tree.expr", &ex) &&
    t2.accept(")")
  ))
    return null;
  text = t2;
  return cast(Object) ex.valueType();
}
mixin DefaultParser!(gotTypeof, "type.of", "45");

Object gotSizeof(ref string text, ParseCb cont, ParseCb rest) {
  auto t2 = text;
  if (t2.accept("sizeof(")) {
    auto t3 = t2;
    Type ty; Expr ex;
    if (rest(t3, "type", &ty) && t3.accept(")")) {
      text = t3;
      return new IntExpr(ty.size);
    }
    if (rest(t3, "tree.expr", &ex) && t3.accept(")")) {
      text = t3;
      return new IntExpr(ex.valueType().size);
    }
    throw new Exception(Format(
      "Failed to match parameter for sizeof expression at ", t2.next_text()
    ));
  } else return null;
}
mixin DefaultParser!(gotSizeof, "tree.expr.sizeof", "51");

Object gotTypeStringof(ref string text, ParseCb cont, ParseCb rest) {
  auto t2 = text;
  IType ty;
  if (!rest(t2, "type", &ty))
    return null;
  if (!t2.accept(".stringof")) return null;
  text = t2;
  return new StringExpr(Format(ty));
}
mixin DefaultParser!(gotTypeStringof, "tree.expr.type_stringof", "30");

import tools.log;
Object gotPartialStringof(ref string text, ParseCb cont, ParseCb rest) {
  return lhs_partial.using = delegate Object(Expr ex) {
    if (text.accept(".stringof")) {
      // logln("got ", Format(ex));
      return new StringExpr(Format(ex));
    }
    else return null;
  };
}
mixin DefaultParser!(gotPartialStringof, "tree.rhs_partial.stringof");