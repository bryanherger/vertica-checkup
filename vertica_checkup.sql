-- check non-default configurations
select distinct parameter_name,current_value,default_value
from vs_configuration_parameters
where current_value <> default_value and parameter_name not in ('DataSSLParams', 'AWSAuth','SSLPrivateKey','LDAPLinkBindPswd','SecurityAlgorithm'); 
-- notes: do the listed non-default values still make sense for current applications and workload?

-- Check delete vectors
SELECT count(*) as DVcount, sum(deleted_row_count) as DVrows, sum(used_bytes) as DVbytes, sum(used_bytes)::float/count(*) as DVavgsize FROM DELETE_VECTORS;
-- notes: delete vectors can significantly affect performance as they are silently reprocessed for every query on the attached table.  See the blog post at
-- https://www.vertica.com/blog/watch-those-delete-vectors/ for more detail on how delete vectors work and how to manage them.

-- Check UDP errors and spread retransmissions
SELECT time,node_name, 
udp_in_errors_end_value -udp_in_errors_start_value upd_packet_receive_errors, 
udp_in_datagrams_end_value -udp_in_datagrams_start_value udp_packets_received, 
udp_out_datagrams_end_value-udp_out_datagrams_start_value upd_packet_sent 
FROM dc_netstats_by_minute 
WHERE time > 
( SELECT max(time)-7 FROM dc_netstats_by_minute) 
AND udp_in_errors_end_value-udp_in_errors_start_value > 0 
ORDER BY 3 DESC limit 50; 
-- notes: if there are a lot of UDP errors, check kernel networking settings in sysctl.  See the instruction document for more info.

select time,node_name,time_interval,retrans,packet_count,retrans_per_second FROM (
SELECT a.time, a.node_name, a.time_interval, a.retrans,a.packet_count AS packet_count, ((a.retrans / (a.time_interval / '00:00:01'::interval)))::numeric(18,2) AS retrans_per_second 
FROM ( SELECT (dc_spread_monitor.time)::timestamp AS time, 
dc_spread_monitor.node_name, 
(dc_spread_monitor.retrans - lag(dc_spread_monitor.retrans, 1, NULL::int) OVER (partition BY dc_spread_monitor.node_name ORDER BY (dc_spread_monitor.time)::timestamp)) AS retrans, 
(((dc_spread_monitor.time)::timestamp - lag((dc_spread_monitor.time)::timestamp, 1, NULL::timestamp) OVER (partition BY dc_spread_monitor.node_name ORDER BY (dc_spread_monitor.time)::timestamp))) AS time_interval, 
(dc_spread_monitor.packet_sent - lag(dc_spread_monitor.packet_sent, 1, NULL::int) OVER (partition BY dc_spread_monitor.node_name ORDER BY (dc_spread_monitor.time)::timestamp)) AS packet_count 
FROM dc_spread_monitor ) a 
WHERE a.retrans > 0 OR a.packet_count > 0 ORDER BY a.time, a.node_name) b WHERE retrans_per_second > 10 
ORDER BY 4 DESC limit 50; 
-- notes: if there are a lot of spread retransmits, check kernel networking settings in sysctl.  See the instruction document for more info.

-- Check for superprojections
select distinct schema_name as schema_name ,anchortablename as table_name, sum(total_row_count) as table_row_count
from storage_containers join vs_projections on projection_id = oid and seginfo <> 0 and createtype ='A'
group by schema_name,anchortablename, projection_name
having sum(total_row_count) > 100000000
order by 3 desc limit 50 ; 
-- notes: tables with more than 100M rows should have a custom projection defined to reduce table size with compression and optimize query and loading.
-- Run DataBase Designer in incremental mode to create projections for new tables.

-- projection skew
select schema_name as schema_name , projection_name, min(cnt) as min_count,avg(cnt)::int as avg_count, max(cnt) as max_count ,
((max(cnt)*100/min(cnt))-100)::int as skew_percent 
from (select node_name,schema_name,projection_name,sum(total_row_count - deleted_row_count) as cnt
from storage_containers group by 1,2,3 having sum(total_row_count - deleted_row_count) > 100000000 ) foo 
group by 1,2 
having ((max(cnt)*100/min(cnt))-100)::int > 10 
order by 5 desc limit 50;
-- notes: projection skew means rows are concentrated on specific nodes rather than evenly balanced.  This means certain nodes will have higher workload and slower response.
-- Some ways to correct skew include re-running DBD and running rebalance.

-- TM quick check
select operation,plan_type,
avg(cnt)::int avg_ops_per_hour,
max(cnt)::int max_ops_per_hour,
(avg(scnt) / 1000000000)::numeric(18,2) avg_gigabytes_per_hour,
count(*) as retention_history_hours 
from ( select operation,plan_type,node_name,count(*) cnt,sum(container_count) ccnt,sum(total_size_in_bytes) scnt 
from dc_tuple_mover_events 
group by
node_name,operation,plan_type,date_trunc('hour',time)) a group by operation,plan_type 
order by 3 desc;
-- notes: high TM actions per hour means datra load may not be optimized, which will slow down the system overall.

-- RP quick check
select ra.pool_name pool_name, memorysize_kb, maxmemorysize_kb, planned_concurrency, max_concurrency,query_budget_kb,percentile90_query_runtime_ms query_runtime_ms, number_of_queries, CASE WHEN (query_budget_kb < 1048576 and percentile90_query_runtime_ms > 1000 and ra.pool_name not in ('general','sysquery') ) THEN cast('1048576' as varchar(10)) WHEN ( query_budget_kb > 8388608 and ra.pool_name not in ('general','sysquery')) THEN cast('8388608' as varchar(10)) WHEN ( percentile75_memory_usage_kb < 1048576 and ra.pool_name not in ('general','sysquery')) THEN cast('1048576' as varchar(10)) WHEN ( ABS(percentile75_memory_usage_kb-query_budget_kb) > 1048576 and ra.pool_name not in ('general','sysquery')) THEN cast(percentile75_memory_usage_kb as varchar(10)) WHEN ( ra.pool_name = 'sysquery') THEN cast('102400' as varchar(10)) WHEN ( ra.pool_name = 'general') THEN ' ' ELSE ' ' END Recommended_QueryBudget_KB, CASE WHEN (query_budget_kb < 1000000 and percentile90_query_runtime_ms > 1000 and ra.pool_name not in ('general','sysquery') ) THEN cast( 'alter resource pool '||ra.pool_name || ' plannedconcurrency ' || ((planned_concurrency*query_budget_kb/1048576)+.5 )::int || ';' as varchar(100)) WHEN ( query_budget_kb > 8000000 and ra.pool_name not in ('general','sysquery')) THEN cast( 'alter resource pool '||ra.pool_name || ' plannedconcurrency ' || ((planned_concurrency*query_budget_kb/8388608)+.5 )::int || ';' as varchar(100)) WHEN ( percentile75_memory_usage_kb < 1000000 and ra.pool_name not in ('general','sysquery')) THEN cast( 'alter resource pool '||ra.pool_name || ' plannedconcurrency ' || ((planned_concurrency*query_budget_kb/1048576)+.5 )::int || ';' as varchar(100)) WHEN ( ABS(percentile75_memory_usage_kb-query_budget_kb) > 1000000 and ra.pool_name not in ('general','sysquery')) THEN cast(((planned_concurrency*query_budget_kb/percentile75_memory_usage_kb)+.5 )::int as varchar(100)) WHEN ( ra.pool_name = 'sysquery') THEN cast( 'alter resource pool '||ra.pool_name || ' plannedconcurrency ' || ((planned_concurrency*query_budget_kb/102400)+.5 )::int || ';' as varchar(100)) WHEN ( ra.pool_name = 'general') THEN ' ' ELSE ' ' END Recommendation FROM ( SELECT pool_name, approximate_percentile(memory_used_kb using parameters percentile = 0.75)::int percentile75_memory_usage_kb, approximate_percentile(query_runtime_ms using parameters percentile = 0.90)::int percentile90_query_runtime_ms, count(*) number_of_queries FROM (SELECT pool_name,transaction_id, statement_id,max(memory_inuse_kb) memory_used_kb,max(duration_ms) query_runtime_ms FROM resource_acquisitions GROUP BY 1,2, 3 ) foo GROUP BY 1 )ra JOIN ( SELECT pool_name, planned_concurrency,max_concurrency,max(memory_size_kb)memorysize_kb,max(max_memory_size_kb) maxmemorysize_kb, max(query_budget_kb) query_budget_kb FROM resource_pool_status GROUP BY 1,2,3) rps ON ra.pool_name=rps.pool_name ;
-- notes: Resource Pools can be tuned using a formula to calculate query budget (memory/maxmemory) and recommended concurrency.

-- Check query_events and other tables for issues and suggested fixes
-- notes: all of the below show Vertica internal reporting on information, warnings, errors encountered during operation.  query_events and dc_errors provide suggestions on how to correct issues, while you can
-- refer to documentation, the forum, and Vertica support for advice on how to correct any other issues found in these tables.  Issues observed may repeat between outputs if the same issue affects multiple stages.
-- events from query_events
select event_description, suggested_action, count(*) count,min(event_timestamp) first_occurrence, max(event_timestamp) last_occurrence from query_events where suggested_action is not null and suggested_action <> 'Informational; No user action is necessary' group by 1,2 order by 3 desc;
-- events from execution engine and optimizer
select event_description, count, first_occurrence, last_occurrence from
( (select event_description,count(*) count,min(time) first_occurrence, max(time) last_occurrence
from dc_execution_engine_events
where suggested_action <> '' and suggested_action not ilike '%informational%' group by 1 order by 2 desc limit 5)
union all
(select event_description,count(*) count,min(time) first_occurrence,max(time) last_occurrence
from dc_optimizer_events
where suggested_action <> '' and suggested_action not ilike '%informational%' group by 1 order by 2 desc limit 5)
) foo order by 2 desc;
-- ERROR and PANIC events from dc_errors
select error_level_name as error_level,max(message)::varchar(50) message,
max(log_hint)::varchar(40) resolution_hint,count(*) cnt,min(time) first_occurrence, max(time) last_occurrence 
from dc_errors 
where (error_level_name='PANIC' ) or ( error_level_name = 'ERROR' and error_code in (8389,197)
and vertica_code not in (5147,4381,5952,2296,3895,4524,3895) )
group by error_level_name
order by 4 desc limit 20; 

-- check connection load balancing.  Are some users or jobs targeting one node for all of their DDL / DML?
select start_timestamp::date, node_name, user_name, count(*) from query_requests group by start_timestamp::date, node_name, user_name order by start_timestamp::date, node_name, user_name;
-- notes: as with projection skew, users or applications that only send queries or data loads to one node will cause that node to have a higher workload and slower response, which slows the
-- system overall.  Check whether system usage is relatively balanced.


