module ast.main;

import ast.base, ast.fun, ast.intrinsic, ast.modules, ast.namespace;
import ast.scopes, ast.arrays, ast.returns, ast.parse, ast.pointer;

void fixupMain() {
  auto cmain = fastcast!(Function)~ sysmod.lookup("__c_main");
  if (!cmain) { logln("fail 0: ", cmain); fail(); }
  auto sc = fastcast!(Scope)~ cmain.tree;
  if (!sc) { logln("fail 1: ", cmain.tree); fail(); }
  auto argvar = fastcast!(Expr)~ sc.lookup("args");
  if (!argvar) { logln("fail 2: ", sc.field); fail(); }
  auto cvar = fastcast!(Expr)~ sc.lookup("argc"), pvar = fastcast!(Expr)~ sc.lookup("argv");
  if (!gotMain) {
    logln("main function not found! ");
    fail();
  }
  auto call = gotMain.mkCall();
  
  auto m = gotMain;
  bool mainReturnsInt, mainTakesStrings, mainTakesArgCV; // argc, argv
  with (m.type) {
    if (ret == Single!(SysInt))
      mainReturnsInt = true;
    if (!params.length) { }
    else {
      if (params.length == 2) {
        if (params[0].type == Single!(SysInt) && params[1].type == Single!(Pointer, Single!(Pointer, Single!(Char))))
          mainTakesArgCV = true;
        else {
          logln("invalid main form (1): ", m.type);
          fail();
        }
      } else if (params.length == 1) {
        if (params[0].type == Single!(Array, Single!(Array, Single!(Char))))
          mainTakesStrings = true;
        else {
          logln("invalid main form (2): ", m.type);
          fail();
        }
      } else {
        logln("invalid main form (3): ", m.type);
        fail();
      }
    }
  }
  
  if (mainTakesStrings) call.params ~= argvar;
  if (mainTakesArgCV) call.params ~= [cvar, pvar];
  Statement res;
  
  auto backup = namespace();
  scope(exit) namespace.set(backup);
  namespace.set(cmain);
  
  if (mainReturnsInt) res = new ReturnStmt(call);
  else res = new ExprStatement(call);
  sc.addStatement(res);
}
