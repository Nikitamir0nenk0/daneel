TABLE_NAME = "analytics.book_demand_showcase_core"
CLICKHOUSE_CONN_ID = "CLICKHOUSE_CHS53_ANALYTICS_DCR"


def build_insert_sql_window(window_start: str, window_end: str) -> str:
    return f"""
INSERT INTO {TABLE_NAME}
WITH shops AS (
    SELECT
        pt_id AS shop_id
    FROM analytics.retail_shops_info
    WHERE city = 'Москва'
      AND brand IN ('ЧГ', 'Буквоед')
      AND date_opened <= today() - 180
      AND (date_closed IS NULL OR date_closed > today())
      AND date_transport_stop IS NULL
      AND channel_id = 1
),
active_shop_books AS (
    SELECT DISTINCT
        pt_id AS shop_id,
        toInt64(goods_id) AS book_id
    FROM analytics.wh_remainder_shops
    WHERE toDate(ondate) >= today() - 180
      AND toDate(ondate) < today()
      AND pt_id IN (SELECT shop_id FROM shops)
      AND rem > 0
),
rubric_filter AS (
    SELECT DISTINCT
        toInt64(book_id) AS book_id
    FROM analytics.ncat_first_180d_catalog
    WHERE rubric_name NOT IN (
        'Средняя школа',
        'Подготовка к экзаментам',
        'Раскраски',
        'Начальная школа',
        'Книги-игрушки',
        'Внеклассное чтение',
        'Подготовка к школе',
        'Детская религиозная литература'
    )
),
eligible_books AS (
    SELECT DISTINCT
        toInt64(book_id) AS book_id
    FROM analytics.recsys_catalog_pim
    WHERE available_for_sale = 1
      AND category_1_id = '18030'
      AND toInt64(book_id) IN (SELECT book_id FROM rubric_filter)
),
eligible_shop_books AS (
    SELECT
        asb.shop_id,
        asb.book_id
    FROM active_shop_books asb
    INNER JOIN eligible_books eb ON asb.book_id = eb.book_id
),
stock_daily AS (
    SELECT
        toDate(ondate) - 1 AS day,
        pt_id            AS shop_id,
        toInt64(goods_id) AS book_id,
        rem              AS stock_rem
    FROM analytics.wh_remainder_shops
    WHERE toDate(ondate) >= toDate('{window_start}') + 1
      AND toDate(ondate) <  toDate('{window_end}')   + 2
      AND (pt_id, toInt64(goods_id)) IN (
          SELECT shop_id, book_id FROM eligible_shop_books
      )
),
sales_daily AS (
    SELECT
        toDate(operation_day) AS day,
        toInt64(shop)         AS shop_id,
        toInt64(goods_id)     AS book_id,
        sum(goods_quantity)   AS qty_sold
    FROM analytics.cdm_retail_receipts
    WHERE toDate(operation_day) >= toDate('{window_start}')
      AND toDate(operation_day) <= toDate('{window_end}')
      AND is_internet_sale = 'Оффлайн'
      AND is_normal = 1
      AND (goods_storno IS NULL OR goods_storno = 0)
      AND (is_1_rub_sale IS NULL OR is_1_rub_sale = 0)
      AND directory_type = 11
      AND (toInt64(shop), toInt64(goods_id)) IN (
          SELECT shop_id, book_id FROM eligible_shop_books
      )
    GROUP BY day, shop_id, book_id
)
SELECT
    sd.day                              AS day,
    toUInt64(sd.shop_id)                AS shop_id,
    toUInt64(sd.book_id)                AS book_id,
    toUInt32(coalesce(s.qty_sold, 0))   AS qty_sold,
    toInt32(sd.stock_rem)               AS stock_rem,
    now() + INTERVAL 3 HOUR             AS upload_time
FROM stock_daily sd
LEFT JOIN sales_daily s
    ON  s.day     = sd.day
    AND s.shop_id = sd.shop_id
    AND s.book_id = sd.book_id
WHERE sd.day >= toDate('{window_start}')
  AND sd.day <= toDate('{window_end}')
"""
