module ast.properties;

import ast.base, ast.parse, ast.casting, ast.tuples: AstTuple = Tuple;

TLS!(PropArgs) propcfg;

static this() { New(propcfg); }

TLS!(char*) rawmode_loc;

static this() { New(rawmode_loc); }

bool rawmode(string s) {
  return s.ptr == *rawmode_loc.ptr();
}

// placed here to break import cycle
import ast.vardecl;
Object gotLVize(ref string text, ParseCb cont, ParseCb rest) {
  Expr ex;
  auto t2 = text;
  
  // behaves like a fun call
  auto backup = *propcfg.ptr();
  scope(exit) *propcfg.ptr() = backup;
  propcfg.ptr().withTuple = false;
  
  if (!rest(t2, "tree.expr _tree.expr.bin"[], &ex))
    t2.failparse("Expected expression for lvize"[]);
  text = t2;
  return fastcast!(Object) (lvize(ex));
}
mixin DefaultParser!(gotLVize, "tree.expr.lvize"[], "24071"[], "lvize"[]);
