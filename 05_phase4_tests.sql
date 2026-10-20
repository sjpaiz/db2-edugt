-- EDUGT - FASE 4
SET NOCOUNT ON;
GO


-- PRUEBA 1: VERIFICACION DE PROCEDIMIENTOS
SELECT
    'sp_RefundEnrollment' AS object_name,
    CASE
        WHEN OBJECT_ID(
            'dbo.sp_RefundEnrollment', 'P'
        ) IS NOT NULL
        THEN 'PASS'
        ELSE 'FAIL'
    END AS test_result

UNION ALL

SELECT
    'sp_SettleBillingPeriod',
    CASE
        WHEN OBJECT_ID(
            'dbo.sp_SettleBillingPeriod', 'P'
        ) IS NOT NULL
        THEN 'PASS'
        ELSE 'FAIL'
    END;
GO

-- PRUEBA 2: VERIFICACION DE COLUMNAS
SELECT
    'chargebacks.status' AS column_name,
    CASE
        WHEN COL_LENGTH(
            'dbo.chargebacks', 'status'
        ) IS NOT NULL
        THEN 'PASS'
        ELSE 'FAIL'
    END AS test_result

UNION ALL

SELECT
    'chargebacks.remaining_amount',
    CASE
        WHEN COL_LENGTH(
            'dbo.chargebacks', 'remaining_amount'
        ) IS NOT NULL
        THEN 'PASS'
        ELSE 'FAIL'
    END

UNION ALL

SELECT
    'cohorts.max_capacity',
    CASE
        WHEN COL_LENGTH(
            'dbo.cohorts', 'max_capacity'
        ) IS NOT NULL
        THEN 'PASS'
        ELSE 'FAIL'
    END;
GO


-- PRUEBA 3: INTEGRIDAD DE CUPOS
SELECT
    c.id AS cohort_id,
    c.course_id,
    c.max_capacity,
    c.occupied_slots,

    COUNT(e.id) AS enrolled_students,

    c.occupied_slots - COUNT(e.id)
        AS slot_difference

FROM dbo.cohorts AS c

LEFT JOIN dbo.enrollments AS e
    ON e.cohort_id = c.id
   AND e.status IN ('active', 'completed')

GROUP BY
    c.id,
    c.course_id,
    c.max_capacity,
    c.occupied_slots

HAVING
    c.occupied_slots <> COUNT(e.id)
    OR c.occupied_slots > c.max_capacity
    OR c.occupied_slots < 0;
GO

-- PRUEBA 4: BILLETERAS CON SALDOS NEGATIVOS
SELECT
    id AS wallet_id,
    user_id,
    balance

FROM dbo.wallets

WHERE balance < 0;
GO


-- PRUEBA 5: REEMBOLSOS APROBADOS
SELECT
    r.id AS refund_id,
    r.enrollment_id,
    r.amount AS refunded_amount,
    r.status AS refund_status,
    e.status AS enrollment_status

FROM dbo.refunds AS r

INNER JOIN dbo.enrollments AS e
    ON e.id = r.enrollment_id

WHERE r.status = 'approved'
  AND e.status <> 'refunded';
GO


-- PRUEBA 6: REEMBOLSOS DUPLICADOS
SELECT
    enrollment_id,
    COUNT(*) AS approved_refunds

FROM dbo.refunds

WHERE status = 'approved'

GROUP BY enrollment_id

HAVING COUNT(*) > 1;
GO


-- PRUEBA 7: MONTOS DE REEMBOLSO
SELECT
    r.id AS refund_id,
    r.enrollment_id,
    r.amount AS refund_amount,
    e.amount_paid AS enrollment_amount

FROM dbo.refunds AS r

INNER JOIN dbo.enrollments AS e
    ON e.id = r.enrollment_id

WHERE r.status = 'approved'
  AND r.amount <> e.amount_paid;
GO


-- PRUEBA 8: MOVIMIENTOS DE REEMBOLSO
SELECT
    r.id AS refund_id,
    r.enrollment_id,
    r.amount

FROM dbo.refunds AS r

WHERE r.status = 'approved'
  AND NOT EXISTS (
      SELECT 1
      FROM dbo.wallet_movements AS wm
      WHERE wm.refund_id = r.id
        AND wm.type = 'credit'
        AND wm.concept = 'refund'
        AND wm.amount = r.amount
  );
GO


-- PRUEBA 9: LIQUIDACIONES DUPLICADAS
SELECT
    period_id,
    course_id,
    COUNT(*) AS settlement_count

FROM dbo.course_settlements

GROUP BY
    period_id,
    course_id

HAVING COUNT(*) > 1;
GO


-- PRUEBA 10: CUADRE DE LIQUIDACIONES
SELECT
    cs.id AS settlement_id,
    cs.period_id,
    cs.course_id,
    cs.gross_revenue,
    cs.platform_commission,

    COALESCE(
        SUM(p.net_amount), 0
    ) AS total_payouts,

    COALESCE(
        SUM(p.negative_adjustments), 0
    ) AS total_adjustments,

    cs.gross_revenue
    - cs.platform_commission
    - COALESCE(SUM(p.net_amount), 0)
    - COALESCE(SUM(p.negative_adjustments), 0)
        AS balance_difference

FROM dbo.course_settlements AS cs

LEFT JOIN dbo.payouts AS p
    ON p.settlement_id = cs.id

GROUP BY
    cs.id,
    cs.period_id,
    cs.course_id,
    cs.gross_revenue,
    cs.platform_commission

HAVING ABS(
    cs.gross_revenue
    - cs.platform_commission
    - COALESCE(SUM(p.net_amount), 0)
    - COALESCE(SUM(p.negative_adjustments), 0)
) > 0.001;
GO


-- PRUEBA 11: CONTRACARGOS INCONSISTENTES
SELECT
    id AS chargeback_id,
    course_instructor_id,
    refund_id,
    adjustment_amount,
    remaining_amount,
    status

FROM dbo.chargebacks

WHERE adjustment_amount >= 0
   OR remaining_amount < 0
   OR remaining_amount > ABS(adjustment_amount)
   OR (
       status = 'settled'
       AND remaining_amount <> 0
   )
   OR (
       status IN ('pending', 'partial')
       AND remaining_amount = 0
   );
GO


-- PRUEBA 12: APLICACIONES DE CONTRACARGOS
SELECT
    cb.id AS chargeback_id,
    cb.adjustment_amount,
    cb.remaining_amount,

    COALESCE(
        SUM(ca.amount_applied), 0
    ) AS applied_amount

FROM dbo.chargebacks AS cb

LEFT JOIN dbo.chargeback_applications AS ca
    ON ca.chargeback_id = cb.id

GROUP BY
    cb.id,
    cb.adjustment_amount,
    cb.remaining_amount

HAVING ABS(
    ABS(cb.adjustment_amount)
    - cb.remaining_amount
    - COALESCE(SUM(ca.amount_applied), 0)
) > 0.001;
GO


-- PRUEBA 13: PAGOS NEGATIVOS
SELECT
    id AS payout_id,
    settlement_id,
    course_instructor_id,
    negative_adjustments,
    net_amount

FROM dbo.payouts

WHERE net_amount < 0
   OR negative_adjustments < 0;
GO


-- PRUEBA 14: PERIODOS CERRADOS
SELECT
    id AS period_id,
    [year],
    [month],
    status,
    processed_at

FROM dbo.billing_periods

WHERE status = 'closed'
  AND processed_at IS NULL;
GO

-- PRUEBA 15: INSCRIPCIONES LIQUIDADAS
SELECT
    id AS enrollment_id,
    student_id,
    course_id,
    settlement_status,
    period_id

FROM dbo.enrollments

WHERE settlement_status = 'settled'
  AND period_id IS NULL;
GO


-- PRUEBA 16: NOTIFICACIONES DE REEMBOLSO
SELECT
    r.id AS refund_id,
    e.student_id,
    r.resolved_at

FROM dbo.refunds AS r

INNER JOIN dbo.enrollments AS e
    ON e.id = r.enrollment_id

WHERE r.status = 'approved'
  AND NOT EXISTS (
      SELECT 1
      FROM dbo.notifications AS n
      WHERE n.user_id = e.student_id
        AND n.type = 'refund'
        AND n.subject = 'Refund approved'
  );
GO


-- PRUEBA 17: ESTADO DE LOS PERIODOS
SELECT
    id AS period_id,
    [year],
    [month],
    starts_at,
    closes_at,
    status,
    processed_at

FROM dbo.billing_periods

ORDER BY
    [year] DESC,
    [month] DESC;
GO

-- PRUEBA 18: VERIFICACION DE INDICES
SELECT
    'IX_f4_reviews_finished_reviewer'
        AS index_name,

    CASE
        WHEN EXISTS (
            SELECT 1
            FROM sys.indexes
            WHERE object_id =
                OBJECT_ID('dbo.academic_reviews')
              AND name =
                'IX_f4_reviews_finished_reviewer'
        )
        THEN 'PASS'
        ELSE 'FAIL'
    END AS test_result

UNION ALL

SELECT
    'IX_f4_enrollments_course_enrolled_at',

    CASE
        WHEN EXISTS (
            SELECT 1
            FROM sys.indexes
            WHERE object_id =
                OBJECT_ID('dbo.enrollments')
              AND name =
                'IX_f4_enrollments_course_enrolled_at'
        )
        THEN 'PASS'
        ELSE 'FAIL'
    END;
GO

PRINT 'Phase 4 integrity checks completed.';
GO
