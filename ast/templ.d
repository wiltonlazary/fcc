module ast.templ;

import ast.base, ast.parse, ast.modules, ast.namespace, ast.fun;

interface ITemplate : Named {
  Object getInstanceIdentifier(IType it, ParseCb rest, string name);
}

extern(C) bool _isITemplate(Object obj) { return !!fastcast!(ITemplate)(obj); }

interface ITemplateX : ITemplate { // extended template-like
  bool isAliasTemplate();
  TemplateInstance getInstance(IType type, ParseCb rest);
  TemplateInstance getInstance(Tree tr, ParseCb rest);
  Object postprocess(Object obj);
}

void delegate()[] resetDgs;
void resetTemplates() { foreach (dg; resetDgs) dg(); }

class RelTemplate : ITemplateX {
  Template sup;
  Expr ex;
  this(Template t, Expr e) { sup = t; ex = e; }
  override {
    bool isAliasTemplate() { return sup.isAliasTemplate(); }
    string getIdentifier() { return sup.getIdentifier(); }
    Object getInstanceIdentifier(IType it, ParseCb rest, string name) {
      logln("rel mew ", name);
      return sup.getInstanceIdentifier(it, rest, name);
    }
    TemplateInstance getInstance(IType type, ParseCb rest) {
      auto res = sup.getInstance(type, rest);
      logln("rel mew2 ", res);
      return res;
    }
    TemplateInstance getInstance(Tree tr, ParseCb rest) {
      auto res = sup.getInstance(tr, rest);
      logln("rel mew3 ", res);
      return res;
    }
    Object postprocess(Object obj) {
      logln("postprocess ", obj.classinfo.name, ", ", obj);
      logln("expr is ", ex);
      scope(exit) logln("done");
      auto rt = fastcast!(RelTransformable) (obj);
      if (!rt) return obj;
      return rt.transform(ex);
    }
  }
}

class Template : ITemplateX, SelfAdding, RelTransformable /* for templates in structs */ {
  string name;
  string param;
  bool isAlias;
  override bool isAliasTemplate() { return isAlias; }
  string source; // HAX
  Namespace context;
  union {
    Stuple!(TemplateInstance, IType)[] emat_type; // past tense of emit
    Stuple!(TemplateInstance, Tree)[] emat_alias;
  }
  this() { resetDgs ~= &resetme; }
  void resetme() { emat_type = null; emat_alias = null; }
  override {
    Object transform(Expr base) {
      return new RelTemplate(this, base);
    }
    TemplateInstance getInstance(IType type, ParseCb rest) {
      assert(!isAlias);
      TemplateInstance ti;
      foreach (entry; emat_type)
        // weirdness with tuples in sieve.cr
        // TODO: unhax.
        if (Format(entry._1) == Format(type)) { ti = entry._0; break; }
        // if (entry._1 == type) { return entry._0; }
      if (!ti) {
        ti = new TemplateInstance(this, type, rest);
        emat_type ~= stuple(ti, type);
      }
      ti.emitCopy();
      return ti;
    }
    TemplateInstance getInstance(Tree tr, ParseCb rest) {
      assert(isAlias);
      TemplateInstance ti;
      foreach (entry; emat_alias)
        if (entry._1 == tr) { ti = entry._0; break; }
      if (!ti) {
        ti = new TemplateInstance(this, tr, rest);
        emat_alias ~= stuple(ti, tr);
      }
      ti.emitCopy();
      return ti;
    }
    Object getInstanceIdentifier(IType type, ParseCb rest, string name) {
      return getInstance(type, rest).lookup(name, true);
    }
    string getIdentifier() { return name; }
    bool addsSelf() { return true; }
    string toString() {
      return Format("template ", name);
    }
    Object postprocess(Object obj) { return obj; }
  }
}

Object gotTemplate(ref string text, ParseCb cont, ParseCb rest) {
  auto t2 = text;
  auto tmpl = new Template;
  if (!(t2.gotIdentifier(tmpl.name) && t2.accept("(") && (t2.accept("alias") && test(tmpl.isAlias = true) || true) && t2.gotIdentifier(tmpl.param) && t2.accept(")")))
    t2.failparse("Failed parsing template header");
  tmpl.source = t2.getHeredoc();
  tmpl.context = namespace();
  text = t2;
  namespace().add(tmpl.name, tmpl);
  return tmpl;
}
// a_ so this comes first .. lol
mixin DefaultParser!(gotTemplate, "tree.toplevel.a_template", null, "template");
mixin DefaultParser!(gotTemplate, "struct_member.struct_template", null, "template");

import tools.log;

import ast.structure;
class TemplateInstance : Namespace, HandlesEmits {
  Namespace context;
  union {
    IType type;
    Tree tr;
  }
  Template parent;
  IsMangled[] instRes;
  this(Template parent, IType type, ParseCb rest) {
    this.type = type;
    this.parent = parent;
    assert(!parent.isAlias);
    __add(parent.param, fastcast!(Object)~ type);
    this.sup = context = parent.context;
    this(rest);
  }
  this(Template parent, Tree tr, ParseCb rest) {
    this.tr = tr;
    this.parent = parent;
    assert(parent.isAlias);
    __add(parent.param, fastcast!(Object)~ tr);
    this.sup = context = parent.context;
    this(rest);
  }
  Module[] ematIn;
  void emitCopy(bool weakOnly = false) {
    if (!instRes) return;
    auto mod = current_module();
    foreach (emod; ematIn) if (emod is mod) return;
    if (weakOnly) {
      foreach (inst; instRes) if (auto fun = fastcast!(Function) (inst)) if (fun.weak) {
        mod.entries ~= fastcast!(Tree) (fun.dup);
      }
    } else {
      foreach (inst; instRes) {
        mod.entries ~= fastcast!(Tree) (inst).dup;
      }
    }
    ematIn ~= mod;
  }
  this(ParseCb rest) {
    withTLS(namespace, this, {
      auto t2 = parent.source;
      pushCache(); // open new memoizer level
      scope(exit) popCache();
      Object obj;
      
      string parsemode = "tree.toplevel";
      if (fastcast!(Structure) (context))
        parsemode = "struct_member";
      
      // logln("template context is ", (cast(Object) context).classinfo.name);
      // logln("rest toplevel match on ", t2);
      if (!t2.many(
        !!rest(t2, parsemode, &obj),
        {
          auto tr = fastcast!(Tree) (obj);
          if (!tr) return;
          if (fastcast!(NoOp) (obj)) return;
          auto n = fastcast!(Named)~ tr;
          // if (!n) throw new Exception(Format("Not named: ", tr));
          if (n && !addsSelf(n)) add(n.getIdentifier(), n);
          if (auto ns = fastcast!(Namespace)~ tr) { // now reset sup to correct target.
            ns.sup = this;
          }
          /*if (auto fun = fastcast!(Function)~ tr)
            logln("add ", fun.mangleSelf(), " to ", current_module().name,
              ", at ", current_module().entries.length, "; ", cast(void*) current_module());*/
          // current_module().entries ~= tr;
          auto mg = fastcast!(IsMangled) (tr);
          if (!mg) { logln("!! ", tr); asm { int 3; } }
          mg.markWeak();
          // addExtra(mg);
          instRes ~= mg;
        }
      ) || t2.mystripl().length)
        t2.failparse("Failed to parse template content");
      
    });
  }
  override {
    string toString() {
      if (parent.isAlias) return Format("Instance of ", parent, " (", tr, ") <- ", sup);
      else return Format("Instance of ", parent, " (", type, ") <- ", sup);
    }
    string mangle(string name, IType type) {
      string mangl;
      if (parent.isAlias) {
        if (auto fun = fastcast!(Function)~ tr) {
          mangl = fun.mangleSelf();
          // logln("mangl => ", mangl);
        } else assert(false, Format(tr));
      } else mangl = this.type.mangle();
      return sup.mangle(name, type)~"__"~"templinst_"~parent.name.cleanup()~"_with_"~mangl;
    }
    Stuple!(IType, string, int)[] stackframe() { assert(false); }
  }
}

Object gotTemplateInst(bool RHSMode)(ref string text, ParseCb cont, ParseCb rest) {
  auto t2 = text;
  Object getInstance(Object obj) {
    auto t = fastcast!(ITemplateX) (obj);
    if (!t) return null;
    if (!t2.accept("!")) return null;
    TemplateInstance inst;
    if (t.isAliasTemplate()) {
      Tree tr;
      if (!rest(t2, "tree.expr.named", &tr))
        t2.failparse("Couldn't match tree object for instantiation");
      inst = t.getInstance(tr, rest);
    } else {
      IType ty;
      if (!rest(t2, "type", &ty))
        t2.failparse("Couldn't match type for instantiation");
      inst = t.getInstance(ty, rest);
    }
    if (auto res = inst.lookup(t.getIdentifier(), true)) return t.postprocess(res);
    else throw new Exception("Template '"~t.getIdentifier()~"' contains no self-named entity! ");
  }
  static if (RHSMode) {
    return lhs_partial.using = delegate Object(Object obj) {
      auto res = getInstance(obj);
      if (res) text = t2;
      return res;
    };
  } else {
    Object obj;
    if (!rest(t2, "tree.expr.named", &obj)) return null;
    auto res = getInstance(obj);
    if (res) text = t2;
    return res;
  }
  // logln("instantiate ", t.name, " with ", ty);
}
mixin DefaultParser!(gotTemplateInst!(false), "type.templ_inst", "2");
mixin DefaultParser!(gotTemplateInst!(false), "tree.expr.templ_expr", "2401");
mixin DefaultParser!(gotTemplateInst!(true), "tree.rhs_partial.instance");

import ast.funcall;
Object gotIFTI(ref string text, ParseCb cont, ParseCb rest) {
  auto t2 = text;
  return lhs_partial.using = delegate Object(Object obj) {
    Expr iter;
    auto templ = fastcast!(ITemplate) (obj);
    if (!templ) return null;
    Expr nex;
    if (!rest(t2, "tree.expr", &nex)) return null;
    auto res = templ.getInstanceIdentifier(nex.valueType(), rest, templ.getIdentifier());
    auto fun = fastcast!(Function) (res);
    if (!fun) { return null; }
    text = t2;
    auto fc = buildFunCall(fun, nex, "template_call");
    if (!fc) {
      logln("Couldn't build fun call! ");
      asm { int 3; }
    }
    return fastcast!(Object) (fc);
  };
}
mixin DefaultParser!(gotIFTI, "tree.rhs_partial.ifti");
