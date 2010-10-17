module ast.withstmt;

import ast.base, ast.parse, ast.vardecl, ast.namespace, ast.guard, ast.scopes, ast.fun;

class WithStmt : Namespace, Statement, ScopeLike {
  RelNamespace rns;
  Namespace ns;
  VarDecl vd;
  Expr context;
  Scope sc;
  IScoped isc;
  void delegate(AsmFile) pre, post;
  mixin defaultIterate!(vd, sc);
  override WithStmt dup() { assert(false, "wth"); }
  string toString() { return Format("with (", context, ") <- ", sup); }
  int temps;
  override int framesize() {
    return (cast(ScopeLike) sup).framesize() + temps;
  }
  this(Expr ex) {
    sup = namespace();
    namespace.set(this);
    scope(exit) namespace.set(this.sup);
    
    sc = new Scope;
    assert(!!sc.fun);
    
    if (auto isc = cast(IScoped) ex) {
      this.isc = isc;
      ex = isc.getSup;
      pre = &isc.emitAsmStart;
      temps += ex.valueType().size;
      post = &isc.emitAsmEnd;
      assert(!!cast(LValue) ex || !!cast(MValue) ex, Format(ex, " which is ", isc, ".getSup; is not an LValue/MValue. Halp. "));
    }
    
    if (auto onUsing = iparse!(Statement, "onUsing", "tree.semicol_stmt.expr", canFail)("eval (ex.onUsing)", "ex", ex)) {
      pre = stuple(pre, onUsing) /apply/ (typeof(pre) pre, Statement st, AsmFile af) { if (pre) pre(af); st.emitAsm(af); };
    }
    if (auto onExit = iparse!(Statement, "onExit", "tree.semicol_stmt.expr", canFail)("eval (ex.onExit)", "ex", ex)) {
      post = stuple(post, onExit) /apply/ (typeof(post) post, Statement st, AsmFile af) { st.emitAsm(af); if (post) post(af); };
    }
    
    rns = cast(RelNamespace) ex.valueType();
    
    if (auto srns = cast(SemiRelNamespace) ex.valueType()) rns = srns.resolve();
    ns = cast(Namespace) ex; // say, context
    assert(rns || ns, Format("Cannot with-expr a non-[rel]ns: ", ex)); // TODO: select in gotWithStmt
    
    if (auto lv = cast(LValue) ex) {
      context = lv;
    } else if (auto mv = cast(MValue) ex) {
      context = mv;
    } else {
      auto var = new Variable;
      var.type = ex.valueType();
      var.initval = ex;
      var.baseOffset = boffs(var.type);
      temps += var.type.size;
      context = var;
      New(vd);
      vd.vars ~= var;
    }
  }
  override {
    void emitAsm(AsmFile af) {
      mixin(mustOffset("0"));
      
      if (pre) pre(af);
      scope(exit) if (post) post(af);
      
      auto dg = sc.open(af);
      if (vd) vd.emitAsm(af);
      dg()();
    }
    string mangle(string name, IType type) { return sup.mangle(name, type); }
    Stuple!(IType, string, int)[] stackframe() {
      auto res = sup.stackframe();
      if (vd)
        foreach (var; vd.vars)
          res ~= stuple(var.type, var.name, var.baseOffset);
      return res;
    }
    Object lookup(string name, bool local = false) {
      if (rns)
        if (auto res = rns.lookupRel(name, context))
          return res;
      if (ns)
        if (auto res = ns.lookup(name, true))
          return res;
      // if (local) return null;
      return sup.lookup(name);
    }
  }
}

import tools.log;
Object gotWithStmt(ref string text, ParseCb cont, ParseCb rest) {
  auto t2 = text;
  // if (!t2.accept("with")) return null;
  if (!t2.accept("using")) return null;
  Expr ex;
  if (!rest(t2, "tree.expr", &ex)) throw new Exception("Couldn't match with-expr at "~t2.next_text());
  auto backup = namespace();
  scope(exit) namespace.set(backup);
  auto ws = new WithStmt(ex);
  namespace.set(ws.sc);
  if (!rest(t2, "tree.stmt", &ws.sc._body)) throw new Exception("Couldn't match with-body at "~t2.next_text());
  text = t2;
  return ws;
}
mixin DefaultParser!(gotWithStmt, "tree.stmt.withstmt");

Object gotBackupOf(ref string text, ParseCb cont, ParseCb rest) {
  auto t2 = text;
  if (!t2.accept("backupof(")) return null;
  string name;
  if (t2.gotIdentifier(name) && t2.accept(")")) {
    auto ws = namespace().get!(WithStmt);
    string[] names;
    do {
      if (!ws.isc) continue;
      auto n = cast(Named) ws.isc.getSup();
      if (!n) continue;
      auto ident = n.getIdentifier();
      if (ident == name)
        return ws.vd.vars[0];
      names ~= ident;
    } while (test(ws = ws.get!(WithStmt)));
    throw new Exception(Format("No backup for ", name, ", only ", names, ". "));
  } else throw new Exception("Failed to parse backupof() at '"~t2.next_text()~"'. ");
}
mixin DefaultParser!(gotBackupOf, "tree.expr.backupof", "52");
