-- showcase_v2_multi_brand.sql
-- Витрина v2: day × shop × book
-- Изменения относительно v1:
--   1. Добавлены оба бренда: ЧГ (Читай-город) и Буквоед
--   2. Добавлено поле `brand` — идентификатор бренда магазина
--   3. Фильтр brand заменён на IN ('ЧГ', 'Буквоед')
-- Зерно: одна строка на (day, shop_id, book_id)

WITH

-- 1. Магазины обоих брендов: ЧГ и Буквоед, Москва, открытые >= 180 дней
shops AS (
    SELECT *
    FROM (
        SELECT
            pt_id                                           AS shop_id,
            argMax(short_name,        date_update)          AS shop_name,
            argMax(brand,             date_update)          AS brand,          -- NEW: идентификатор бренда
            argMax(pl_simple_name,    date_update)          AS shop_pl_simple_name,
            argMax(branch_name,       date_update)          AS shop_branch,
            argMax(category_11,       date_update)          AS shop_category_11,
            argMax(power_11,          date_update)          AS shop_power_11,
            argMax(partner_format_id, date_update)          AS shop_format_id
        FROM analytics.retail_shops_info
        WHERE brand IN ('ЧГ', 'Буквоед')           -- CHANGED: оба бренда
          AND city  = 'Москва'
          AND date_opened <= today() - 180
          AND (date_closed IS NULL OR date_closed > today())
          AND date_transport_stop IS NULL
        GROUP BY pt_id
    )
    ORDER BY shop_power_11 DESC
    LIMIT 20                                         -- увеличен лимит: по ~10 на бренд
),

-- 2. Каталог книг (без изменений)
books AS (
    SELECT
        toInt64(book_id)            AS book_id,
        name                        AS book_name,
        writers_last_names          AS author_last_name,
        publisher,
        publisher_series            AS series_name,
        cycle_id,
        category_1,   category_1_id,
        category_2,   category_2_id,
        category_3,   category_3_id,
        category_4,   category_4_id,
        page_count,
        size,
        binding_type,
        total_amount                AS print_run,
        weight,
        age_restriction,
        first_publication_date      AS first_pub_date,
        last_publication_date       AS last_pub_date,
        preorder_status,
        videos_cnt,
        excerpts_cnt,
        additional_images_cnt
    FROM analytics.recsys_catalog_pim
    WHERE available_for_sale = 1
      AND category_1_id = '18030'   -- только книги
),

-- 3. Ежедневные остатки
stock_daily AS (
    SELECT
        toDate(ondate)              AS stock_date,
        toInt64(goods_id)           AS goods_id,
        pt_id                       AS shop_id,
        argMax(rem, ondate)         AS stock_rem
    FROM analytics.wh_remainder_shops
    WHERE toDate(ondate) >= today() - 37    -- скользящее окно
      AND toDate(ondate) <  today()
      AND pt_id IN (SELECT shop_id FROM shops)
    GROUP BY stock_date, goods_id, shop_id
),

-- 4. Ежедневные продажи
sales_daily AS (
    SELECT
        toDate(operation_day)                                    AS sale_date,
        toInt64(goods_id)                                        AS goods_id,
        shop                                                     AS shop_id,
        sumIf(goods_quantity,       goods_quantity > 0)          AS qty_sold,
        sumIf(goods_sale_amount,    goods_sale_amount > 0)       AS revenue,
        countIf(goods_quantity < 0)                              AS n_returns,
        abs(sumIf(goods_quantity,   goods_quantity < 0))         AS qty_returned,
        sumIf(goods_discount_value, goods_discount_value > 0)    AS total_discount,
        if(
            sumIf(goods_quantity, goods_quantity > 0) > 0,
            sumIf(goods_sale_amount, goods_sale_amount > 0)
                / sumIf(goods_quantity, goods_quantity > 0),
            NULL
        )                                                        AS avg_unit_price,
        max(toUInt8(goods_discount_value > 0))                   AS has_any_discount
    FROM analytics.cdm_retail_receipts
    WHERE toDate(operation_day) >= today() - 37
      AND toDate(operation_day) <  today()
      AND shop         IN (SELECT shop_id FROM shops)
      AND is_internet_sale = 'Оффлайн'
      AND is_normal = 1
      AND (goods_storno  IS NULL OR goods_storno  = 0)
      AND (is_1_rub_sale IS NULL OR is_1_rub_sale = 0)
      AND directory_type = 11
    GROUP BY sale_date, goods_id, shop_id
)

-- 5. Итоговая матрица: day × shop × book
SELECT
    sd.stock_date                           AS day,
    sd.shop_id,
    sh.brand,                               -- NEW: бренд магазина ('ЧГ' или 'Буквоед')
    sd.goods_id                             AS book_id,
    coalesce(s.qty_sold,   0)               AS target,
    coalesce(sd.stock_rem, 0)               AS stock_rem,
    toUInt8(sd.stock_rem <= 0)              AS is_stockout,
    sh.shop_name,
    sh.shop_pl_simple_name,
    sh.shop_branch,
    sh.shop_category_11,
    sh.shop_power_11,
    sh.shop_format_id,
    s.revenue,
    s.avg_unit_price,
    s.n_returns,
    s.qty_returned,
    s.total_discount,
    s.has_any_discount,
    b.book_name,
    b.author_last_name,
    b.publisher,
    b.series_name,
    b.cycle_id,
    b.category_1,   b.category_1_id,
    b.category_2,   b.category_2_id,
    b.category_3,   b.category_3_id,
    b.category_4,   b.category_4_id,
    b.print_run,
    b.page_count,
    b.weight,
    b.size,
    b.binding_type,
    b.age_restriction,
    b.first_pub_date,
    b.last_pub_date,
    b.preorder_status,
    b.videos_cnt,
    b.excerpts_cnt,
    b.additional_images_cnt
FROM stock_daily AS sd
INNER JOIN shops       AS sh ON sh.shop_id  = sd.shop_id
INNER JOIN books       AS b  ON b.book_id   = sd.goods_id
LEFT  JOIN sales_daily AS s  ON s.shop_id   = sd.shop_id
                             AND s.sale_date = sd.stock_date
                             AND s.goods_id  = sd.goods_id
ORDER BY day, sh.brand, sd.shop_id, sd.goods_id
