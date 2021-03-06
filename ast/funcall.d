module ast.funcall;

import ast.fun, ast.base, ast.vardecl, ast.aggregate, ast.structure, ast.namespace, ast.nestfun, ast.structfuns, ast.pointer;

alias ast.fun.Argument Argument;

IType[] relevant(IType[] array) {
  IType[] res;
  foreach (it; array)
    if (!Format(it).startsWith("fpos of a"[])) res ~= it;
  return res;
}

Object gotNamedArg(ref string text, ParseCb cont, ParseCb rest) {
  auto t2 = text;
  string name;
  Expr base;
  if (t2.accept("=>")) { // named flag
    if (!t2.gotIdentifier(name))
      t2.failparse("Flag expected");
    base = fastcast!(Expr) (sysmod.lookup("true"));
  } else {
    if (!t2.gotIdentifier(name)) return null;
    if (!t2.accept("=>")) return null;
    if (!rest(t2, "tree.expr"[], &base))
      t2.failparse("Could not get base expression for named argument '", name, "'");
  }
  auto res = fastalloc!(NamedArg)(name, text, base);
  text = t2;
  return res;
}
mixin DefaultParser!(gotNamedArg, "tree.expr.named_arg_1", "115"); // must be high-priority (above bin) to override subtraction.
mixin DefaultParser!(gotNamedArg, "tree.expr.named_arg_2", "221"); // must be below bin too, to be usable in stuff like paren-less calls

bool matchedCallWith(Expr arg, Argument[] params, ref Expr[] res, out Statement[] inits, Function fun, lazy string info, string text = null, bool probe = false, bool exact = false, int* scorep = null) {
  
  auto r = extractBaseRef(fun);
  
  Expr fixup_init_ex(Expr ex) {
    void check(ref Iterable it) {
      if (auto rm = fastcast!(RelTransformable)(it)) {
        it = fastcast!(Iterable)(rm.transform(r));
      }
      it.iterate(&check);
    }
    auto it = fastcast!(Iterable)(ex);
    check(it);
    ex = fastcast!(Expr)(it);
    return ex;
  }
  
  Expr[string] nameds;
  bool changed;
  void removeNameds(ref Iterable it) {
    // logln("removeNameds <", fastcast!(Object)(it).classinfo.name, " ", it, ">");
    if (fastcast!(Variable) (it)) return;
    if (auto ex = fastcast!(Expr) (it)) {
      ex = collapse(ex); // resolve alias
      if (auto tup = fastcast!(AstTuple) (ex.valueType())) {
        bool canHaveNameds = true;
        if (fastcast!(StatementAndExpr) (ex)) canHaveNameds = false;
        if (canHaveNameds) {
          // filter out nameds from the tuple.
          auto exprs = getTupleEntries(ex, null, true);
          bool gotNamed;
          
          bool backup = changed;
          changed = false;
          scope(exit) changed = backup;
          
          foreach (ref subexpr; exprs) {
            auto sit = fastcast!(Iterable) (subexpr);
            removeNameds(sit);
            subexpr = fastcast!(Expr) (sit);
          }
          foreach (i, ref subexpr; exprs) {
            if (fastcast!(NamedArg) (subexpr)) {
              gotNamed = true;
              break;
            }
          }
          Expr[] left;
          foreach (i, subexpr; exprs) {
            if (auto na = fastcast!(NamedArg) (subexpr)) {
              changed = true;
              nameds[na.name] = na.base;
            } else if (subexpr.valueType() != mkTuple()) {
              left ~= subexpr;
            } else changed = true;
          }
          exprs = left;
          if (changed) it = mkTupleExpr(exprs);
          changed = false;
        }
      }
      if (auto na = fastcast!(NamedArg) (ex)) {
        changed = true;
        nameds[na.name] = na.base;
        it = mkTupleExpr();
      }
    }
  }
  {
    Iterable forble = arg;
    removeNameds(forble);
    void checkNameds(ref Iterable it) {
      if (fastcast!(Variable) (it)) return;
      if (fastcast!(FunCall) (it)) return;
      /*logln("<", (cast(Object) it).classinfo.name, ">");
      if (auto rce = fastcast!(RCE) (it)) {
        logln(" - ", rce.to);
      }*/
      if (auto na = fastcast!(NamedArg) (it)) {
        // fail;
        throw new Exception(Format("Leftover named-arg found! ", na, " (couldn't remove)"));
      }
      if (fastcast!(AstTuple)(it)) it.iterate(&checkNameds);
      // logln("</", (cast(Object) it).classinfo.name, ">");
    }
    checkNameds(forble);
    arg = fastcast!(Expr)~ forble;
  }
  
  Expr[] args;
  args ~= arg;
  Expr[] flatten(Expr ex) {
    if (fastcast!(AstTuple)~ ex.valueType()) {
      Statement st;
      auto res = getTupleEntries(ex, &st);
      if (st) inits ~= st;
      return res;
    } else {
      return null;
    }
  }
  int flatLength(Expr ex) {
    int res;
    if (fastcast!(AstTuple)~ ex.valueType()) {
      foreach (entry; getTupleEntries(ex, null, true))
        res += flatLength(entry);
    } else {
      res ++;
    }
    return res;
  }
  int flatArgsLength() {
    int res;
    foreach (arg; args) res += flatLength(arg);
    return res;
  }
  foreach (i, tuple; params) {
    auto type = tuple.type, name = tuple.name;
    type = resolveType(type);
    if (fastcast!(Variadic) (type)) {
      foreach (ref rest_arg; args)
        if (!gotImplicitCast(rest_arg, (IType it) { return !fastcast!(StaticArray) (it); }))
          throw new Exception(Format("Invalid argument to variadic: ", rest_arg));
      res ~= args;
      args = null;
      break;
    }
    {
      IType[] tried;
      if (auto p = name in nameds) {
        auto ex = *p, backup = ex;
        nameds.remove(name);
        if (exact) {
          if (ex.valueType() != type)
            if (probe)
              return false;
            else
              text.failparse("Couldn't match named argument ", name, " of ", backup.valueType(), " exactly to function call '", info(), "', ", type, ".");
        } else {
          if (!gotImplicitCast(ex, type, (IType it) { tried ~= it; return test(it == type); }, false))
            if (probe)
              return false;
            else
              text.failparse("Couldn't match named argument ", name, " of ", backup.valueType(), " to function call '", info(), "', ", type, "; tried ", tried, ".");
        }
        res ~= ex;
        continue;
      }
    }
    if (!flatArgsLength() && flatLength(fastalloc!(Placeholder)(tuple.type))) {
      // logln("args.length = 0 for ", arg, " at ", i, " in ", params);
      if (tuple.initEx) {
        auto ex = fixup_init_ex(tuple.initEx);
        IType[] tried;
        if (exact) {
          if (ex.valueType() != type)
            if (probe)
              return false;
            else
              text.failparse("Couldn't match default argument for ", name, ": ", tuple.initEx.valueType(), " exactly to ", type, ".");
        } else {
          if (!gotImplicitCast(ex, type, (IType it) { tried ~= it; return test(it == type); }, false))
            if (probe)
              return false;
            else
              text.failparse("Couldn't match default argument for ", name, ": ", tuple.initEx.valueType(), " to ", type,"; tried ", tried, ".");
        }
        res ~= ex;
        continue;
      }
      if (probe) return false;
      if (text) {
        if (nameds) 
          text.failparse("Not enough parameters for '", info(), "'; left over ", type, " or unable to assign named parameters ", nameds.keys);
        text.failparse("Not enough parameters for '", info(), "'; left over ", type, "!");
      }
      logln("Not enough parameters for '", info(), "'; left over ", type, "!");
      fail;
    }
    IType[] tried;
  retry:
    auto ex = args.take();
    auto backup = ex;
    
    // because reasons. KEEP IN.
    // opt(ex);
    // DONT TELL ME WHAT TO DO
    ex = collapse(ex);
    
    int score;
    
    bool matches;
    if (exact) matches = test(ex.valueType() == type);
    else {
      try matches = gotImplicitCast(ex, type, (IType it) {
          tried ~= it;
          // logln(ex, " !! is ", it, " == ", type, "? ", test(it == type), " with ", score);
          return test(it == type);
        }, false, &score);
      catch (Exception ex) {
        text.failparse("While attempting to cast to ", type, ": ", ex);
      }
      // logln("score = ", score);
    }
    
    if (!matches) {
      Expr[] list;
      if (gotImplicitCast(ex, Single!(HintType!(Tuple)), (IType it) { return !!fastcast!(Tuple) (it); }) && (list = flatten(ex), !!list)) {
        args = list ~ args;
        goto retry;
      } else {
        if (probe) return false;
        string formatlines(IType[] types) {
          string res;
          foreach (i, type; types)
            res ~= qformat(" ", i, ": ", type, "\n");
          if (!res) res = " none\n";
          res = res[0..$-1];
          return res;
        }
        text.failparse("Couldn't match\n",
          "  ", backup.valueType(), "\n",
          "to function call '", info(), "' (", i, "):\n"
          "  ", params[i], "\n",
          "tried:\n", formatlines(relevant(tried)));
      }
    }
    // if (scorep) logln("add to ", *scorep, ": ", score);
    if (scorep) *scorep += score;
    res ~= ex;
  }
  Expr[] flat;
  void recurse(Expr ex) {
    if (fastcast!(AstTuple)~ ex.valueType())
      foreach (entry; flatten(ex)) recurse(entry);
    else flat ~= ex;
  }
  foreach (arg2; args) recurse(arg2);
  if (flat.length) {
    IType[] types;
    foreach (a; flat) types ~= a.valueType();
    // text.failparse("Extraneous parameters to '", info(), "' of ", params, ": ", types);
    text.setError("Extraneous parameters to '"[], info(), "' of "[], params, ": "[], types);
    return false;
  }
  if (nameds.length) {
    string fninfo = info();
    if (!fninfo) fninfo = "function";
    // throw new Exception(Format(fninfo, " has no arguments named "[], nameds.keys));
    text.setError(fninfo, " has no arguments named "[], nameds.keys);
    return false;
  }
  return true;
}

bool cantBeCall(string s) {
  // brackets are always implicit terminators. this prevents the ugliness of };
  // if (s.hadABracket()) return true;
  auto s2 = s;
  if (s2.hadABracket()) {
    while (s2.length && s2[0] == ' ') s2 = s2[1..$];
    if (s2.length && (s2[0] == '\r' || s2[0] == '\n')) return true;
  }
  return s.accept(".") || s.accept("{");
}

Expr extractBaseRef(Function fun) {
  if (auto rf = fastcast!(RelFunction)(fun)) {
    return rf.baseptr;
  }
  if (auto pf_nf = fastcast!(PointerFunction!(NestedFunction))(fun)) {
    auto ex = pf_nf.ptr;
    if (auto dce = fastcast!(DgConstructExpr)(ex)) {
      return fastalloc!(DerefExpr)(dce.data);
    }
    return null;
  }
  // if ((cast(Object)fun).classinfo.name != "ast.fun.Function")
  //   logln((cast(Object)fun).classinfo.name, " ", fun);
  return null;
}

import ast.properties;
import ast.tuple_access, ast.tuples, ast.casting, ast.fold, ast.tuples: AstTuple = Tuple;
bool matchCall(ref string text, Function fun, lazy string lazy_info, Argument[] params, ParseCb rest, ref Expr[] res, out Statement[] inits, bool test, bool precise, bool allowAutoCall, int* scorep = null) {
  string infocache;
  string info() { if (!infocache) infocache = lazy_info(); return infocache; }
  
  int neededParams;
  foreach (par; params) if (!par.initEx) neededParams ++;
  
  bool paramless;
  if (!neededParams) {
    auto t2 = text;
    // paramless call
    if (t2.accept(";")) paramless = true;
  }
  Expr arg;
  
  auto backup_text = text; 
  if (!backup_text.length) return false; // wat
  
  auto t2 = text;
  
  if (paramless) arg = mkTupleExpr();
  else {
    bool isTuple;
    {
      auto t3 = text;
      if (t3.accept("(")) isTuple = true;
    }

    // Only do this if we actually expect a tuple _literal_
    // properties on tuple _variables_ are valid!
    auto backup = *propcfg.ptr();
    scope(exit) *propcfg.ptr() = backup;
    if (isTuple) propcfg().withTuple = false;
    
    if (!rest(t2, "tree.expr _tree.expr.bin"[], &arg)) {
      if (params.length) return false;
      else if (info().startsWith("delegate"[])) return false;
      else if (allowAutoCall) arg = mkTupleExpr();
      else return false;
    }
  }
  if (!matchedCallWith(arg, params, res, inits, fun, info(), backup_text, test, precise, scorep)) return false;
  text = t2;
  return true;
}

pragma(set_attribute, _buildFunCall, externally_visible);
extern(C) Expr _buildFunCall(Object obj, Expr arg, string info) {
  const bool probe = true; // allow returning null
  Expr tryWith(Function fun) {
    auto fc = fun.mkCall();
    Statement[] inits;
    if (!matchedCallWith(arg, fun.getParams(false), fc.params, inits, fun, info, null, probe))
      return null;
    if (!inits.length) return fc;
    else if (inits.length > 1) inits = [fastalloc!(AggrStatement)(inits)];
    return mkStatementAndExpr(inits[0], fc);
  }
  if (auto fun = fastcast!(Function) (obj)) {
    return tryWith(fun);
  } else if (auto os = fastcast!(OverloadSet) (obj)) {
    Expr[] candidates;
    foreach (osfun; os.funs) {
      if (auto res = tryWith(osfun)) candidates ~= res;
    }
    if (!candidates) return null;
    if (candidates.length > 1) {
      logln("tried to call overloaded function but more than one overload matched: ", candidates);
      fail;
    }
    return candidates[0];
  } else {
    logln("you want me to call a ", obj, "?");
    fail;
  }
}

import ast.parse, ast.static_arrays;
Object gotCallExpr(ref string text, ParseCb cont, ParseCb rest) {
  auto t2 = text;
  return lhs_partial.using = delegate Object(Object obj) {
    if (t2.cantBeCall()) return null;
    // is this an expr that has alternatives? ie. is it okay to maybe return null here?
    bool exprHasAlternativesToACall;
    auto oobj = obj;
    if (auto nobj = getOpCall(obj)) { exprHasAlternativesToACall = true; obj = nobj; }
    {
      auto t3 = t2;
      if (t3.accept(",") || t3.accept(";")) exprHasAlternativesToACall = true; // may be alias
    }
    Function fun;
    if (auto f = fastcast!(Function) (obj)) {
      fun = f;
    } else if (auto os = fastcast!(OverloadSet) (obj)) {
      bool precise = true;
      retry_match:
      Function[] candidates;
      typeof(fun.getParams(false))[] parsets, candsets;
      int[] scores;
      foreach (osfun; os.funs) {
        auto t3 = t2;
        Statement[] inits;
        // logln(t3.nextText(), ": consider ", osfun);
        int score;
        auto call = osfun.mkCall();
        if (matchCall(t3, osfun, osfun.name, osfun.getParams(false), rest, call.params, inits, true, precise, !exprHasAlternativesToACall, &score)) {
          // logln("params = ", call.params);
          if (auto scd = fastcast!(Scored)(osfun)) score = scd.getScore(); // give preference to function's own score
          candidates ~= osfun;
          candsets ~= osfun.getParams(false);
          scores ~= score;
          score = 0;
        }
        parsets ~= osfun.getParams(false);
      }
      // logln("candy: ", candidates /map/ (Function f) { return f.type; }, " - ", scores);
      if (!candidates) {
        if (precise) { precise = false; goto retry_match; } // none _quite_ match ..
        if (exprHasAlternativesToACall) return null;
        t2.failparse("Unable to call '", os.name, "': matched none of ", parsets);
      }
      if (candidates.length > 1) {
        // try to select the expr with the lowest score
        int lowest = int.max;
        foreach (score; scores) if (score < lowest) lowest = score;
        // exclude candidates with larger scores
        auto backup = candidates, scores_backup = scores;
        candidates = null; scores = null;
        foreach (i, score; scores_backup) if (score == lowest) {
          candidates ~= backup[i];
          scores ~= score;
        }
      }
      // logln("candy after lowscore: ", candidates);
      if (candidates.length > 1) {
        t2.failparse("Unable to call '", os.name,
          "': ambiguity between ", candsets, " btw ", os.funs, " of score ", scores);
      }
      fun = candidates[0];
    } else return null;
    auto fc = fun.mkCall();
    auto params = fun.getParams(false);
    resetError();
    bool result;
    Statement[] inits;
    Expr res = fc;
    auto t4 = t2;
    try {
      result = matchCall(t2, fun, fun.name, params, rest, fc.params, inits, false, false, !exprHasAlternativesToACall);
    }
    catch (ParseEx pe) text.failparse("cannot call: ", pe);
    catch (Exception ex) text.failparse("cannot call: ", ex);
    if (!result) {
      if (exprHasAlternativesToACall) return null;
      if (t2.accept("("))
        t2.failparse("Failed to call function of ", params, ": call did not match");
      auto t3 = t2;
      int neededParams;
      foreach (param; params) if (!param.initEx) neededParams ++;
      if (neededParams || !t3.acceptTerminatorSoft()) {
        t2.failparse("Failed to build paramless call");
      }
    }
    if (inits.length > 1) inits = [fastalloc!(AggrStatement)(inits)];
    if (inits.length) res = mkStatementAndExpr(inits[0], foldex(fc));
    else res = foldex(res);
    text = t2;
    return fastcast!(Object) (res);
  };
}
mixin DefaultParser!(gotCallExpr, "tree.rhs_partial.funcall");

class FpCall : Expr {
  Expr fp;
  Expr[] params;
  this(Expr ex) { fp = ex; }
  private this() { }
  mixin DefaultDup!();
  mixin defaultIterate!(fp, params);
  mixin defaultCollapse!();
  string toString() {
    auto fntype = fastcast!(FunctionPointer) (resolveType(fp.valueType()));
    return qformat("pointer call<", fntype, "> ", fp, " ", params);
  }
  override void emitLLVM(LLVMFile lf) {
    auto fntype = fastcast!(FunctionPointer) (resolveType(fp.valueType()));
    callFunction(lf, fntype.ret, false, fntype.stdcall, params, fp);
  }
  override IType valueType() {
    auto fpt = fastcast!(FunctionPointer)(resolveType(fp.valueType()));
    if (!fpt) fail;
    return fpt.ret;
  }
}

Object gotFpCallExpr(ref string text, ParseCb cont, ParseCb rest) {
  auto t2 = text;
  return lhs_partial.using = delegate Object(Expr ex) {
    if (t2.cantBeCall()) return null;
    
    FunctionPointer fptype;
    if (!gotImplicitCast(ex, Single!(HintType!(FunctionPointer)), (IType it) { fptype = fastcast!(FunctionPointer) (it); return !!fptype; }))
      return null;
    
    auto fc = fastalloc!(FpCall)(ex);
    
    Statement[] inits;
    if (!matchCall(t2, fastalloc!(PointerFunction!(Function))(ex), Format("delegate "[], ex.valueType()), fptype.args, rest, fc.params, inits, false, false, false))
      return null;
    
    text = t2;
    Expr res = fc;
    if (inits.length > 1) inits = [fastalloc!(AggrStatement)(inits)];
    if (inits.length) res = mkStatementAndExpr(inits[0], res);
    return fastcast!(Object) (res);
  };
}
mixin DefaultParser!(gotFpCallExpr, "tree.rhs_partial.fpcall");

import ast.dg;
class DgCall : Expr {
  Expr dg;
  Expr[] params;
  mixin DefaultDup!();
  mixin defaultIterate!(dg, params);
  mixin defaultCollapse!();
  override void emitLLVM(LLVMFile lf) {
    auto dgtype = fastcast!(Delegate) (resolveType(dg.valueType()));
    callDg(lf, dgtype.ret, params, dg);
  }
  override IType valueType() {
    return (fastcast!(Delegate) (resolveType(dg.valueType()))).ret;
  }
  override string toString() {
    return qformat(dg, "("[], params, ")"[]);
  }
}

Object gotDgCallExpr(ref string text, ParseCb cont, ParseCb rest) {
  auto t2 = text;
  return lhs_partial.using = delegate Object(Expr ex) {
    if (t2.cantBeCall()) return null;
    
    Delegate dgtype;
    if (!gotImplicitCast(ex, Single!(HintType!(Delegate)), (IType it) { dgtype = fastcast!(Delegate) (it); return !!dgtype; }))
      return null;
    
    auto dc = new DgCall;
    dc.dg = ex;
    Statement[] inits;
    if (!matchCall(t2, fastalloc!(PointerFunction!(NestedFunction))(ex), Format("delegate "[], ex.valueType()), dgtype.args, rest, dc.params, inits, false, false, false))
      return null;
    text = t2;
    Expr res = dc;
    if (inits.length > 1) inits = [fastalloc!(AggrStatement)(inits)];
    if (inits.length) res = mkStatementAndExpr(inits[0], res);
    return fastcast!(Object) (res);
  };
}
mixin DefaultParser!(gotDgCallExpr, "tree.rhs_partial.fpz_dgcall"); // put this after fpcall

import ast.literal_string, ast.modules;

static this() {
  // allow use of .replace in mixins
  funcall_folds ~= delegate Expr(FunCall fc) {
    // if (fc.fun.name.find("replace") != -1)
    //   logln(fc.fun.name, " - ", fastcast!(Module) (fc.fun.sup), " - ", sysmod, " - ", fastcast!(Module)(fc.fun.sup) is sysmod, " and ", fc.getParams());
    if (fc.fun.name != "replace"[] /or/ "[wrap]replace"[]) return null;
    auto smod = fastcast!(Module) (fc.fun.sup);
    if (!smod || !sysmod || smod !is sysmod) return null;
    auto args = fc.getParams();
    if (args.length != 3) {
      logln("wrong number of args found: ", fc, " - ", args);
      fail;
    }
    string[3] str;
    foreach (i, arg; args) {
      if (auto se = fastcast!(StringExpr) (collapse(arg))) str[i] = se.str;
      else {
        // logln("couldn't fold properly because arg was ", arg);
        // fail;
        return null;
      }
    }
    return fastalloc!(StringExpr)(str[0].replace(str[1], str[2]));
  };
}

// helper for ast.fun
pragma(set_attribute, funcall_emit_fun_end_guard, externally_visible);
extern(C) void funcall_emit_fun_end_guard(LLVMFile lf, string name) {
  (fastalloc!(ExprStatement)(buildFunCall(
    sysmod.lookup("missed_return"),
    fastalloc!(StringExpr)(name),
    "missed return signal"
  ))).emitLLVM(lf);
}
