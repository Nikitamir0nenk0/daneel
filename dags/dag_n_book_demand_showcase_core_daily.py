import sys
import datetime
import logging

sys.path.append('/opt/airflow')

from airflow import DAG
from airflow.decorators import task
from airflow.operators.trigger_dagrun import TriggerDagRunOperator

from dags.scripts.lib.additional_utils import on_failure_callback_dwh_clickhouse_tech_channel_alerts
from dags.scripts.ml_team.ml_pipeline.showcase.book_demand_showcase_core_loader import run_window_load

logger = logging.getLogger(__name__)

default_args = {
    'owner': 'mironenko.n',
    'start_date': datetime.datetime(2026, 7, 15),
    'depends_on_past': False,
    'on_failure_callback': on_failure_callback_dwh_clickhouse_tech_channel_alerts,
}

with DAG(
    dag_id='book_demand_showcase_core_daily',
    default_args=default_args,
    schedule_interval='10 6 * * *',
    catchup=False,
    max_active_runs=1,
    tags=['clickhouse', 'showcase', 'books', 'daily', 'ml_team'],
    description='Скользящее окно [D-7, D-1]: delete + insert витрины. Триггерит ML DAG.',
) as dag:

    @task(task_id='load_window')
    def load_window_task():
        today = datetime.date.today()
        window_start = today - datetime.timedelta(days=7)
        window_end = today - datetime.timedelta(days=1)
        logger.info(
            "Запуск загрузки окна [%s, %s]",
            window_start.isoformat(),
            window_end.isoformat(),
        )
        run_window_load(window_start=window_start, window_end=window_end)

    # TriggerDagRunOperator раскомментировать после готовности ML DAG
    # trigger_forecast = TriggerDagRunOperator(
    #     task_id='trigger_book_demand_forecast',
    #     trigger_dag_id='book_demand_forecast_daily',
    #     wait_for_completion=False,
    #     reset_dag_run=True,
    # )

    load_window_task()  # >> trigger_forecast
