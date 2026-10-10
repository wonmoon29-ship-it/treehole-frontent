import { createClient } from '@supabase/supabase-js'

// 读取 .env.local（本地）或 Vercel 环境变量（线上）
const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL

// 优先使用新版 publishable key（sb_publishable_ 开头）；
// 旧版 anon key 只作过渡兜底，Supabase 计划在 2026 年底前弃用。
const supabaseKey =
  process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY ?? process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY

if (!supabaseUrl || !supabaseKey) {
  throw new Error(
    '缺少环境变量：需要 NEXT_PUBLIC_SUPABASE_URL 和 NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY（或旧版 NEXT_PUBLIC_SUPABASE_ANON_KEY）',
  )
}

// 创建并导出一个全局可用的 Supabase 客户端实例
export const supabase = createClient(supabaseUrl, supabaseKey)