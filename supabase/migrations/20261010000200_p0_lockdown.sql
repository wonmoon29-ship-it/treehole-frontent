-- =====================================================================
-- Pisces · P0 安全修复 · 第 2 步（收紧权限）
--
-- ⚠️ 前提：第 1 步已执行，且新版前端已部署到 Vercel 并验证能正常发帖。
--    这一步执行后，旧版前端将无法发帖（它直接往表里写数据）。
--
-- 用法：Supabase 控制台 → SQL Editor → New query → 整段粘贴 → Run
-- 可以重复运行。
--
-- 这一步做了什么：
--   1. 访客不能再直接往 authors / posts / replies 里写任何数据，只能调用发帖函数
--   2. authors 表对访客完全不可读；posts / replies 只开放展示需要的列
--      （author_token、is_hidden 等内部列不可读）
--   3. 被隐藏的帖子，其回复也一并不可见
-- =====================================================================

BEGIN;

DO $$
BEGIN
  IF to_regprocedure('public.create_post(text,text)') IS NULL
     OR to_regprocedure('public.create_reply(uuid,text,text)') IS NULL THEN
    RAISE EXCEPTION '请先运行第 1 步迁移 20261010000100_p0_rpc_identity.sql';
  END IF;
END $$;

-- ---------------------------------------------------------------------
-- 1. 行级策略：删除旧的“任何人可插入 / 可读作者表”策略
-- ---------------------------------------------------------------------
DROP POLICY IF EXISTS "Allow anonymous insert authors" ON public.authors;
DROP POLICY IF EXISTS "Allow anonymous read authors"   ON public.authors;
DROP POLICY IF EXISTS "Allow anonymous insert posts"   ON public.posts;
DROP POLICY IF EXISTS "Allow anonymous insert replies" ON public.replies;
DROP POLICY IF EXISTS "Allow anonymous read posts"     ON public.posts;
DROP POLICY IF EXISTS "Allow anonymous read replies"   ON public.replies;
DROP POLICY IF EXISTS "Public read visible posts"      ON public.posts;
DROP POLICY IF EXISTS "Public read visible replies"    ON public.replies;

ALTER TABLE public.authors ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.posts   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.replies ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Public read visible posts" ON public.posts
  FOR SELECT TO anon, authenticated
  USING (is_hidden = false);

-- 子查询本身也受 posts 的行级策略约束，所以父帖被隐藏时回复也不可见
CREATE POLICY "Public read visible replies" ON public.replies
  FOR SELECT TO anon, authenticated
  USING (is_hidden = false AND EXISTS (SELECT 1 FROM public.posts p WHERE p.id = replies.post_id));

-- ---------------------------------------------------------------------
-- 2. 表权限：先全部收回，再只按列开放读取
-- ---------------------------------------------------------------------
REVOKE ALL ON TABLE public.authors, public.posts, public.replies FROM PUBLIC;
REVOKE ALL ON TABLE public.authors, public.posts, public.replies FROM anon, authenticated;

GRANT SELECT (id, content, created_at, display_id)
  ON public.posts TO anon, authenticated;
GRANT SELECT (id, post_id, content, created_at, display_id)
  ON public.replies TO anon, authenticated;

DO $$
DECLARE
  v_seq text := pg_get_serial_sequence('public.authors', 'display_id');
BEGIN
  EXECUTE format('REVOKE ALL ON SEQUENCE %s FROM PUBLIC, anon, authenticated', v_seq);
END $$;

NOTIFY pgrst, 'reload schema';

COMMIT;

-- =====================================================================
-- 执行后自查（可单独运行）：
--
-- 访客能做什么（应只看到 posts/replies 的几列 SELECT，以及两个函数的 EXECUTE）
--   SELECT grantee, table_name, column_name, privilege_type
--   FROM information_schema.column_privileges
--   WHERE table_schema = 'public' AND grantee IN ('anon', 'authenticated')
--   ORDER BY grantee, table_name, column_name;
--
--   SELECT routine_name, grantee FROM information_schema.routine_privileges
--   WHERE routine_schema IN ('public', 'private') AND grantee IN ('anon', 'authenticated', 'PUBLIC');
-- =====================================================================
