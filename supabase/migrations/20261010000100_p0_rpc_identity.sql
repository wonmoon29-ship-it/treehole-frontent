-- =====================================================================
-- Pisces · P0 安全修复 · 第 1 步（只做增量，不破坏旧版前端）
--
-- 用法：Supabase 控制台 → SQL Editor → New query → 整段粘贴 → Run
-- 可以重复运行。执行后旧版前端仍能正常发帖，新版前端也能用。
--
-- 这一步做了什么：
--   1. 新建 private schema，存放服务端私密 pepper（不会通过 API 暴露）
--   2. 修复已被伪造的号码（重复号、负数号、超出序列的号），并禁止客户端自报号码
--   3. posts / replies 增加 display_id 列，读取时不再需要关联 authors
--   4. 修正“未来时间”或空时间的帖子（否则会永久置顶、逃过 7 天焚毁）
--   5. 内容长度约束：1–200 字（只约束新数据）
--   6. 写入触发器：时间、号码、隐藏状态一律由数据库决定
--   7. 发帖 / 回复函数 create_post / create_reply：身份 token 在服务端用 HMAC 生成
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- 0. 依赖：pgcrypto（Supabase 默认已安装在 extensions schema）
-- ---------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

-- ---------------------------------------------------------------------
-- 1. 私有 schema 与 pepper
--    private 不在 Supabase Data API 的暴露列表里，anon 也没有任何权限。
-- ---------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS private;
REVOKE ALL ON SCHEMA private FROM PUBLIC;
REVOKE ALL ON SCHEMA private FROM anon, authenticated;

CREATE TABLE IF NOT EXISTS private.app_secrets (
  name       text PRIMARY KEY,
  value      bytea NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
REVOKE ALL ON TABLE private.app_secrets FROM PUBLIC;
REVOKE ALL ON TABLE private.app_secrets FROM anon, authenticated;

-- 32 字节随机 pepper，只生成一次；重复运行不会覆盖
INSERT INTO private.app_secrets (name, value)
VALUES ('tripcode_pepper', extensions.gen_random_bytes(32))
ON CONFLICT (name) DO NOTHING;

-- ---------------------------------------------------------------------
-- 2. authors：修复伪造号码，之后禁止客户端指定号码
-- ---------------------------------------------------------------------
UPDATE public.authors SET created_at = now()
WHERE created_at IS NULL OR created_at > now();

DO $$
DECLARE
  v_seq    text := pg_get_serial_sequence('public.authors', 'display_id');
  v_last   bigint;
  v_called boolean;
  v_fixed  integer;
BEGIN
  EXECUTE format('SELECT last_value, is_called FROM %s', v_seq) INTO v_last, v_called;
  IF NOT v_called THEN
    v_last := 0;  -- 序列从未被使用过
  END IF;

  -- 以下号码只可能来自客户端自报：
  --   · 小于等于 0
  --   · 大于序列当前值（序列从没发过这么大的号）
  --   · 出现重复（无法分辨谁是原主，统一重新分配）
  WITH suspicious AS (
    SELECT token FROM public.authors
    WHERE display_id <= 0
       OR display_id > v_last
       OR display_id IN (
            SELECT display_id FROM public.authors
            GROUP BY display_id HAVING count(*) > 1)
  )
  UPDATE public.authors a
  SET display_id = DEFAULT
  FROM suspicious s
  WHERE a.token = s.token;

  GET DIAGNOSTICS v_fixed = ROW_COUNT;
  RAISE NOTICE 'authors：重新分配了 % 个可疑号码', v_fixed;
END $$;

-- 以后只能由数据库发号，且号码唯一
ALTER TABLE public.authors ALTER COLUMN display_id SET GENERATED ALWAYS;
ALTER TABLE public.authors ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE public.authors ALTER COLUMN created_at SET NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.authors'::regclass AND conname = 'authors_display_id_key'
  ) THEN
    ALTER TABLE public.authors ADD CONSTRAINT authors_display_id_key UNIQUE (display_id);
  END IF;
END $$;

-- ---------------------------------------------------------------------
-- 3. posts / replies 冗余保存号码
-- ---------------------------------------------------------------------
ALTER TABLE public.posts   ADD COLUMN IF NOT EXISTS display_id bigint;
ALTER TABLE public.replies ADD COLUMN IF NOT EXISTS display_id bigint;

UPDATE public.posts p SET display_id = a.display_id
FROM public.authors a
WHERE a.token = p.author_token AND p.display_id IS DISTINCT FROM a.display_id;

UPDATE public.replies r SET display_id = a.display_id
FROM public.authors a
WHERE a.token = r.author_token AND r.display_id IS DISTINCT FROM a.display_id;

ALTER TABLE public.posts   ALTER COLUMN display_id SET NOT NULL;
ALTER TABLE public.replies ALTER COLUMN display_id SET NOT NULL;

-- ---------------------------------------------------------------------
-- 4. 修正伪造的时间与隐藏状态
--    · 未来时间 / 空时间：会永久置顶并逃过焚毁 → 改为当前时间（7 天后正常焚毁）
--    · is_hidden 为空：本来就不显示 → 保持隐藏
-- ---------------------------------------------------------------------
UPDATE public.posts   SET created_at = now() WHERE created_at IS NULL OR created_at > now();
UPDATE public.replies SET created_at = now() WHERE created_at IS NULL OR created_at > now();
UPDATE public.posts   SET is_hidden = true WHERE is_hidden IS NULL;
UPDATE public.replies SET is_hidden = true WHERE is_hidden IS NULL;

ALTER TABLE public.posts   ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE public.posts   ALTER COLUMN created_at SET NOT NULL;
ALTER TABLE public.posts   ALTER COLUMN is_hidden  SET DEFAULT false;
ALTER TABLE public.posts   ALTER COLUMN is_hidden  SET NOT NULL;
ALTER TABLE public.replies ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE public.replies ALTER COLUMN created_at SET NOT NULL;
ALTER TABLE public.replies ALTER COLUMN is_hidden  SET DEFAULT false;
ALTER TABLE public.replies ALTER COLUMN is_hidden  SET NOT NULL;

-- ---------------------------------------------------------------------
-- 5. 内容长度约束：1–200 字（按字符计，去掉首尾空白后不能为空）
--    NOT VALID：只检查新写入的数据，历史数据 7 天内会自然焚毁
-- ---------------------------------------------------------------------
ALTER TABLE public.posts DROP CONSTRAINT IF EXISTS posts_content_len_chk;
ALTER TABLE public.posts ADD CONSTRAINT posts_content_len_chk
  CHECK (char_length(content) <= 200 AND btrim(content, E' \t\r\n　') <> '') NOT VALID;

ALTER TABLE public.replies DROP CONSTRAINT IF EXISTS replies_content_len_chk;
ALTER TABLE public.replies ADD CONSTRAINT replies_content_len_chk
  CHECK (char_length(content) <= 200 AND btrim(content, E' \t\r\n　') <> '') NOT VALID;

-- ---------------------------------------------------------------------
-- 6. 写入触发器：不论数据从哪条路径写入，以下字段都由数据库决定
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.tg_authors_before_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  NEW.created_at := now();
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION private.tg_posts_before_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  NEW.created_at := now();
  NEW.is_hidden  := false;
  NEW.display_id := (SELECT a.display_id FROM public.authors a WHERE a.token = NEW.author_token);
  IF NEW.display_id IS NULL THEN
    RAISE EXCEPTION '作者身份不存在' USING ERRCODE = '23503';
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION private.tg_replies_before_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  NEW.created_at := now();
  NEW.is_hidden  := false;
  NEW.display_id := (SELECT a.display_id FROM public.authors a WHERE a.token = NEW.author_token);
  IF NEW.display_id IS NULL THEN
    RAISE EXCEPTION '作者身份不存在' USING ERRCODE = '23503';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.posts p WHERE p.id = NEW.post_id AND p.is_hidden = false) THEN
    RAISE EXCEPTION '该帖子不存在或已被隐藏';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS authors_before_insert ON public.authors;
CREATE TRIGGER authors_before_insert
  BEFORE INSERT ON public.authors
  FOR EACH ROW EXECUTE FUNCTION private.tg_authors_before_insert();

DROP TRIGGER IF EXISTS posts_before_insert ON public.posts;
CREATE TRIGGER posts_before_insert
  BEFORE INSERT ON public.posts
  FOR EACH ROW EXECUTE FUNCTION private.tg_posts_before_insert();

DROP TRIGGER IF EXISTS replies_before_insert ON public.replies;
CREATE TRIGGER replies_before_insert
  BEFORE INSERT ON public.replies
  FOR EACH ROW EXECUTE FUNCTION private.tg_replies_before_insert();

-- ---------------------------------------------------------------------
-- 7. 身份解析与发帖函数
--
--    p_key：浏览器用 PBKDF2 从“身份暗号”派生出的 64 位十六进制串；
--           留空 = 一次性路人（随机身份）。
--    token = HMAC-SHA256(p_key, pepper) 的前 16 字节。
--    pepper 只存在数据库里，所以即使 token 泄露，也无法离线撞出暗号。
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.assert_content(p_content text)
RETURNS void
LANGUAGE plpgsql
IMMUTABLE
SET search_path = ''
AS $$
BEGIN
  IF p_content IS NULL OR btrim(p_content, E' \t\r\n　') = '' THEN
    RAISE EXCEPTION '内容不能为空' USING ERRCODE = '22023';
  END IF;
  IF char_length(p_content) > 200 THEN
    RAISE EXCEPTION '内容不能超过 200 字' USING ERRCODE = '22023';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION private.resolve_author(
  p_key            text,
  OUT o_token      uuid,
  OUT o_display_id bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_pepper bytea;
BEGIN
  IF p_key IS NULL OR p_key = '' THEN
    o_token := gen_random_uuid();
  ELSIF p_key ~ '^[0-9a-f]{64}$' THEN
    SELECT s.value INTO STRICT v_pepper
    FROM private.app_secrets s
    WHERE s.name = 'tripcode_pepper';

    o_token := encode(
      substring(extensions.hmac(decode(p_key, 'hex'), v_pepper, 'sha256') FROM 1 FOR 16),
      'hex'
    )::uuid;
  ELSE
    RAISE EXCEPTION '身份暗号格式无效' USING ERRCODE = '22023';
  END IF;

  -- 先查后插：老身份不会白白消耗序列号，号码保持连续
  SELECT a.display_id INTO o_display_id FROM public.authors a WHERE a.token = o_token;
  IF o_display_id IS NULL THEN
    INSERT INTO public.authors (token) VALUES (o_token)
    ON CONFLICT (token) DO NOTHING
    RETURNING display_id INTO o_display_id;

    IF o_display_id IS NULL THEN  -- 并发时被别的请求抢先插入
      SELECT a.display_id INTO o_display_id FROM public.authors a WHERE a.token = o_token;
    END IF;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.create_post(p_content text, p_key text DEFAULT NULL)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_token      uuid;
  v_display_id bigint;
BEGIN
  PERFORM private.assert_content(p_content);

  SELECT r.o_token, r.o_display_id INTO v_token, v_display_id
  FROM private.resolve_author(p_key) r;

  INSERT INTO public.posts (author_token, content) VALUES (v_token, p_content);
  RETURN v_display_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.create_reply(p_post_id uuid, p_content text, p_key text DEFAULT NULL)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_token      uuid;
  v_display_id bigint;
BEGIN
  PERFORM private.assert_content(p_content);

  -- 先确认帖子可回复，再解析身份，避免失败的请求白占一个号
  IF NOT EXISTS (SELECT 1 FROM public.posts p WHERE p.id = p_post_id AND p.is_hidden = false) THEN
    RAISE EXCEPTION '该帖子不存在或已被隐藏';
  END IF;

  SELECT r.o_token, r.o_display_id INTO v_token, v_display_id
  FROM private.resolve_author(p_key) r;

  INSERT INTO public.replies (post_id, author_token, content) VALUES (p_post_id, v_token, p_content);
  RETURN v_display_id;
END;
$$;

-- ---------------------------------------------------------------------
-- 8. 函数权限：只开放两个发帖函数，private 里的一律不开放
-- ---------------------------------------------------------------------
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA private FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA private FROM anon, authenticated;

REVOKE ALL ON FUNCTION public.create_post(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_reply(uuid, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_post(text, text) FROM anon, authenticated;
REVOKE ALL ON FUNCTION public.create_reply(uuid, text, text) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_post(text, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_reply(uuid, text, text) TO anon, authenticated;

-- 让 API 立即识别新函数和新列
NOTIFY pgrst, 'reload schema';

COMMIT;
