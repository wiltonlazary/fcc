module ast.funcall;

import ast.fun, ast.base;

import ast.tuple_access, ast.tuples, ast.casting, ast.fold, ast.tuples: AstTuple = Tuple;
bool matchCall(ref string text, string info, IType[] params, ParseCb rest, ref Expr[] res) {
  Expr arg;
  auto backup_text = text;
  if (!rest(text, "tree.expr _tree.expr.arith", &arg))
    return false;
  Expr[] args;
  args ~= arg;
  Expr[] flatten(Expr ex) {
    if (cast(AstTuple) ex.valueType())
      return getTupleEntries(ex);
    else
      return null;
  }
  foreach (i, type; params) {
    if (cast(Variadic) type) {
      foreach (ref rest_arg; args)
        if (!gotImplicitCast(rest_arg, (IType it) { return !cast(StaticArray) it; }))
          throw new Exception(Format("Invalid argument to variadic: ", rest_arg));
      res ~= args;
      args = null;
      break;
    }
    if (!args.length) {
      throw new Exception(Format("Not enough parameters for ", info, "!"));
    }
    IType[] tried;
  retry:
    auto ex = args.take();
    auto backup = ex;
    if (!gotImplicitCast(ex, (IType it) {
      tried ~= it;
      return test(it == type);
    })) {
      Expr[] list;
      if (gotImplicitCast(ex, (IType it) { return !!cast(Tuple) it; }) && (list = flatten(ex), !!list)) {
        args = list ~ args;
        goto retry;
      } else
        throw new Exception(Format("Couldn't match ", backup.valueType(), " to function call ", info, ", ", params, "[", i, "]; tried ", tried, " at ", backup_text.next_text()));
    }
    res ~= ex;
  }
  Expr[] flat;
  void recurse(Expr ex) {
    if (cast(AstTuple) ex.valueType())
      foreach (entry; flatten(ex)) recurse(entry);
    else flat ~= ex;
  }
  foreach (arg2; args) recurse(arg2);
  if (flat.length) {
    throw new Exception(Format("Extraneous parameters to '", info, "' of ", params, ": ", args, " at '", backup_text.next_text(), "'. "));
  }
  return true;
}

import ast.parse, ast.static_arrays;
Object gotCallExpr(ref string text, ParseCb cont, ParseCb rest) {
  auto t2 = text;
  return lhs_partial.using = delegate Object(Function fun) {
    auto fc = fun.mkCall();
    IType[] params;
    foreach (entry; fun.type.params) params ~= entry._0;
    if (!matchCall(t2, fun.name, params, rest, fc.params)) {
      auto t3 = t2;
      if (params.length || !t3.accept(";"))
        return null;
    }
    text = t2;
    return fc;
  };
}
mixin DefaultParser!(gotCallExpr, "tree.rhs_partial.funcall", null, true);

class FpCall : Expr {
  Expr fp;
  Expr[] params;
  private this() { }
  mixin DefaultDup!();
  mixin defaultIterate!(params);
  override void emitAsm(AsmFile af) {
    auto fntype = cast(FunctionPointer) fp.valueType();
    callFunction(af, fntype.ret, params, fp);
  }
  override IType valueType() {
    return (cast(FunctionPointer) fp.valueType()).ret;
  }
}

Object gotFpCallExpr(ref string text, ParseCb cont, ParseCb rest) {
  auto t2 = text;
  return lhs_partial.using = delegate Object(Expr ex) {
    auto fptype = cast(FunctionPointer) ex.valueType();
    if (!fptype) return null;
    
    auto fc = new FpCall;
    fc.fp = ex;
    
    if (!matchCall(t2, Format("delegate ", ex), fptype.args, rest, fc.params))
      return null;
    
    text = t2;
    return fc;
  };
}
mixin DefaultParser!(gotFpCallExpr, "tree.rhs_partial.fpcall", null, true);

import ast.dg;
class DgCall : Expr {
  Expr dg;
  Expr[] params;
  mixin DefaultDup!();
  mixin defaultIterate!(dg, params);
  override void emitAsm(AsmFile af) {
    auto dgtype = cast(Delegate) dg.valueType();
    callDg(af, dgtype.ret, params, dg);
  }
  override IType valueType() {
    return (cast(Delegate) dg.valueType()).ret;
  }
}

Object gotDgCallExpr(ref string text, ParseCb cont, ParseCb rest) {
  auto t2 = text;
  return lhs_partial.using = delegate Object(Expr ex) {
    auto dgtype = cast(Delegate) ex.valueType();
    if (!dgtype) return null;
    
    auto dc = new DgCall;
    dc.dg = ex;
    if (!matchCall(t2, Format("delegate ", ex), dgtype.args, rest, dc.params))
      return null;
    text = t2;
    return dc;
  };
}
mixin DefaultParser!(gotDgCallExpr, "tree.rhs_partial.dgcall", null, true);