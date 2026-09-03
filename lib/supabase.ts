import { createClient } from '@supabase/supabase-js'

// 读取 .env.local 中的环境变量
const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL!
const supabaseAnonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!

// 创建并导出一个全局可用的 Supabase 客户端实例
export const supabase = createClient(supabaseUrl, supabaseAnonKey)