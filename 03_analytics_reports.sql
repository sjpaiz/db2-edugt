-- EDUGT - FASE 4
SET NOCOUNT ON;

-- REPORTE 1: RENDIMIENTO DE REVISORES ACADEMICOS
SELECT
    u.id AS reviewer_id,
    CONCAT(u.first_name, ' ', u.last_name) AS reviewer_name,

    COUNT(*) AS courses_reviewed,

    CAST(
        AVG(
            CAST(
                DATEDIFF(MINUTE, ar.started_at, ar.finished_at)
                AS DECIMAL(18,2)
            )
        ) / 60.0
        AS DECIMAL(12,2)
    ) AS average_review_hours,

    SUM(
        CASE WHEN ar.result = 'approved'
        THEN 1 ELSE 0 END
    ) AS approved_courses,

    SUM(
        CASE WHEN ar.result = 'rejected'
        THEN 1 ELSE 0 END
    ) AS rejected_courses,

    CAST(
        100.0 * SUM(
            CASE WHEN ar.result = 'approved'
            THEN 1 ELSE 0 END
        ) / NULLIF(COUNT(*), 0)
        AS DECIMAL(6,2)
    ) AS approval_rate_pct,

    CAST(
        100.0 * SUM(
            CASE WHEN ar.result = 'rejected'
            THEN 1 ELSE 0 END
        ) / NULLIF(COUNT(*), 0)
        AS DECIMAL(6,2)
    ) AS rejection_rate_pct

FROM dbo.academic_reviews AS ar

INNER JOIN dbo.users AS u
    ON u.id = ar.reviewer_id

WHERE ar.finished_at IS NOT NULL
  AND ar.result IN ('approved', 'rejected')

GROUP BY
    u.id,
    u.first_name,
    u.last_name

ORDER BY
    courses_reviewed DESC,
    reviewer_name;


-- REPORTE 2: ACTIVIDAD DE ESTUDIANTES
;WITH enrollment_summary AS (
    SELECT
        student_id,
        COUNT(*) AS total_enrollments,

        SUM(
            CASE WHEN status = 'completed'
            THEN 1 ELSE 0 END
        ) AS completed_courses

    FROM dbo.enrollments
    GROUP BY student_id
),

certificate_summary AS (
    SELECT
        e.student_id,
        COUNT(*) AS total_certificates

    FROM dbo.certificates AS c

    INNER JOIN dbo.enrollments AS e
        ON e.id = c.enrollment_id

    WHERE c.status = 'valid'

    GROUP BY e.student_id
),

study_summary AS (
    SELECT
        e.student_id,

        SUM(
            CAST(COALESCE(l.duration_min, 0) AS BIGINT)
        ) AS estimated_study_minutes

    FROM dbo.lesson_progress AS lp

    INNER JOIN dbo.enrollments AS e
        ON e.id = lp.enrollment_id

    INNER JOIN dbo.lessons AS l
        ON l.id = lp.lesson_id

    WHERE lp.completed_at IS NOT NULL

    GROUP BY e.student_id
)

SELECT
    u.id AS student_id,

    CONCAT(u.first_name, ' ', u.last_name)
        AS student_name,

    u.email,
    u.registered_at AS registration_date,

    COALESCE(es.total_enrollments, 0)
        AS total_enrollments,

    COALESCE(es.completed_courses, 0)
        AS completed_courses,

    COALESCE(cs.total_certificates, 0)
        AS total_certificates,

    CAST(
        COALESCE(ss.estimated_study_minutes, 0) / 60.0
        AS DECIMAL(12,2)
    ) AS estimated_study_hours,

    COALESCE(
        CAST(
            100.0 * COALESCE(es.completed_courses, 0)
            / NULLIF(es.total_enrollments, 0)
            AS DECIMAL(6,2)
        ), 0
    ) AS completion_rate_pct

FROM dbo.users AS u

LEFT JOIN enrollment_summary AS es
    ON es.student_id = u.id

LEFT JOIN certificate_summary AS cs
    ON cs.student_id = u.id

LEFT JOIN study_summary AS ss
    ON ss.student_id = u.id

WHERE u.role = 'student'

ORDER BY
    completed_courses DESC,
    total_enrollments DESC,
    student_name;


-- REPORTE 3: CRECIMIENTO DE INSTRUCTORES
;WITH course_enrollments AS (
    SELECT
        ci.instructor_id,
        e.course_id,

        DATEFROMPARTS(
            YEAR(e.enrolled_at),
            MONTH(e.enrolled_at),
            1
        ) AS enrollment_month,

        COUNT(*) AS enrollment_count

    FROM dbo.enrollments AS e

    INNER JOIN dbo.course_instructors AS ci
        ON ci.course_id = e.course_id

    WHERE e.status <> 'refunded'

    GROUP BY
        ci.instructor_id,
        e.course_id,
        DATEFROMPARTS(
            YEAR(e.enrolled_at),
            MONTH(e.enrolled_at),
            1
        )
),

course_ranges AS (
    SELECT
        instructor_id,
        course_id,
        MIN(enrollment_month) AS first_month,
        MAX(enrollment_month) AS last_month

    FROM course_enrollments

    GROUP BY
        instructor_id,
        course_id
),

month_numbers AS (
    SELECT 0 AS month_offset

    UNION ALL

    SELECT month_offset + 1
    FROM month_numbers
    WHERE month_offset < 1199
),

monthly_series AS (
    SELECT
        cr.instructor_id,
        cr.course_id,
        cr.first_month,
        cr.last_month,

        mn.month_offset AS time_index,

        DATEADD(
            MONTH,
            mn.month_offset,
            cr.first_month
        ) AS enrollment_month

    FROM course_ranges AS cr

    INNER JOIN month_numbers AS mn
        ON mn.month_offset <= DATEDIFF(
            MONTH,
            cr.first_month,
            cr.last_month
        )
),

monthly_data AS (
    SELECT
        ms.instructor_id,
        ms.course_id,
        ms.first_month,
        ms.last_month,
        ms.time_index,
        ms.enrollment_month,

        COALESCE(
            ce.enrollment_count, 0
        ) AS enrollment_count

    FROM monthly_series AS ms

    LEFT JOIN course_enrollments AS ce
        ON ce.instructor_id = ms.instructor_id
       AND ce.course_id = ms.course_id
       AND ce.enrollment_month = ms.enrollment_month
),

growth_summary AS (
    SELECT
        instructor_id,
        course_id,

        MIN(first_month) AS first_month,
        MAX(last_month) AS last_month,

        MAX(
            CASE WHEN time_index = 0
            THEN enrollment_count END
        ) AS first_month_enrollments,

        MAX(
            CASE WHEN enrollment_month = last_month
            THEN enrollment_count END
        ) AS last_month_enrollments,

        SUM(enrollment_count) AS total_enrollments,

        COUNT(*) AS months_analyzed,

        CAST(COUNT(*) AS FLOAT)
            AS n,

        SUM(CAST(time_index AS FLOAT))
            AS sum_x,

        SUM(CAST(enrollment_count AS FLOAT))
            AS sum_y,

        SUM(
            CAST(time_index AS FLOAT)
            * CAST(enrollment_count AS FLOAT)
        ) AS sum_xy,

        SUM(
            CAST(time_index AS FLOAT)
            * CAST(time_index AS FLOAT)
        ) AS sum_x2,

        SUM(
            CAST(enrollment_count AS FLOAT)
            * CAST(enrollment_count AS FLOAT)
        ) AS sum_y2

    FROM monthly_data

    GROUP BY
        instructor_id,
        course_id
),

published_courses AS (
    SELECT
        ci.instructor_id,

        COUNT(DISTINCT ci.course_id)
            AS total_published_courses

    FROM dbo.course_instructors AS ci

    INNER JOIN dbo.courses AS c
        ON c.id = ci.course_id

    WHERE c.published_at IS NOT NULL

    GROUP BY ci.instructor_id
)

SELECT
    u.id AS instructor_id,

    CONCAT(u.first_name, ' ', u.last_name)
        AS instructor_name,

    c.id AS course_id,
    c.title AS course_title,

    gs.first_month,
    gs.last_month,

    gs.first_month_enrollments,
    gs.last_month_enrollments,

    gs.total_enrollments,
    gs.months_analyzed,

    COALESCE(
        CAST(
            100.0 * (
                gs.last_month_enrollments
                - gs.first_month_enrollments
            )
            / NULLIF(gs.first_month_enrollments, 0)
            AS DECIMAL(12,2)
        ), 0
    ) AS enrollment_growth_pct,

    COALESCE(
        pc.total_published_courses, 0
    ) AS total_published_courses,

    -- Calcular la correlacion estadistica de Pearson entre el indice mensual y las inscripciones
    CAST(
        CASE
            WHEN gs.months_analyzed < 2 THEN NULL

            WHEN (
                gs.n * gs.sum_x2
                - gs.sum_x * gs.sum_x
            ) <= 0 THEN NULL

            WHEN (
                gs.n * gs.sum_y2
                - gs.sum_y * gs.sum_y
            ) <= 0 THEN NULL

            ELSE
                (
                    gs.n * gs.sum_xy
                    - gs.sum_x * gs.sum_y
                )
                /
                NULLIF(
                    SQRT(
                        (
                            gs.n * gs.sum_x2
                            - gs.sum_x * gs.sum_x
                        )
                        *
                        (
                            gs.n * gs.sum_y2
                            - gs.sum_y * gs.sum_y
                        )
                    ), 0
                )
        END
        AS DECIMAL(8,4)
    ) AS time_popularity_correlation

FROM growth_summary AS gs

INNER JOIN dbo.users AS u
    ON u.id = gs.instructor_id

INNER JOIN dbo.courses AS c
    ON c.id = gs.course_id

LEFT JOIN published_courses AS pc
    ON pc.instructor_id = gs.instructor_id

ORDER BY
    enrollment_growth_pct DESC,
    instructor_name,
    course_title

OPTION (MAXRECURSION 0);


-- REPORTE 4: METRICAS MENSUALES DE LA PLATAFORMA
;WITH reporting_months AS (
    SELECT
        DATEFROMPARTS([year], [month], 1)
            AS report_month
    FROM dbo.billing_periods

    UNION

    SELECT
        DATEFROMPARTS(
            YEAR(created_at),
            MONTH(created_at),
            1
        )
    FROM dbo.courses

    UNION

    SELECT
        DATEFROMPARTS(
            YEAR(enrolled_at),
            MONTH(enrolled_at),
            1
        )
    FROM dbo.enrollments

    UNION

    SELECT
        DATEFROMPARTS(
            YEAR(issued_at),
            MONTH(issued_at),
            1
        )
    FROM dbo.certificates
),

course_summary AS (
    SELECT
        DATEFROMPARTS(
            YEAR(published_at),
            MONTH(published_at),
            1
        ) AS report_month,

        COUNT(*) AS published_courses

    FROM dbo.courses

    WHERE published_at IS NOT NULL

    GROUP BY
        DATEFROMPARTS(
            YEAR(published_at),
            MONTH(published_at),
            1
        )
),

instructor_summary AS (
    SELECT
        x.report_month,

        COUNT(DISTINCT x.instructor_id)
            AS unique_instructors

    FROM (
        SELECT
            DATEFROMPARTS(
                YEAR(c.published_at),
                MONTH(c.published_at),
                1
            ) AS report_month,

            ci.instructor_id

        FROM dbo.courses AS c

        INNER JOIN dbo.course_instructors AS ci
            ON ci.course_id = c.id

        WHERE c.published_at IS NOT NULL
    ) AS x

    GROUP BY x.report_month
),

enrollment_summary AS (
    SELECT
        DATEFROMPARTS(
            YEAR(enrolled_at),
            MONTH(enrolled_at),
            1
        ) AS report_month,

        COUNT(*) AS total_enrollments,

        COUNT(DISTINCT course_id)
            AS active_courses,

        SUM(
            CASE WHEN status = 'completed'
            THEN 1 ELSE 0 END
        ) AS completed_enrollments

    FROM dbo.enrollments

    GROUP BY
        DATEFROMPARTS(
            YEAR(enrolled_at),
            MONTH(enrolled_at),
            1
        )
),

commission_summary AS (
    SELECT
        DATEFROMPARTS(
            bp.[year],
            bp.[month],
            1
        ) AS report_month,

        SUM(cs.platform_commission)
            AS platform_commission

    FROM dbo.course_settlements AS cs

    INNER JOIN dbo.billing_periods AS bp
        ON bp.id = cs.period_id

    GROUP BY
        DATEFROMPARTS(
            bp.[year],
            bp.[month],
            1
        )
),

certificate_summary AS (
    SELECT
        DATEFROMPARTS(
            YEAR(issued_at),
            MONTH(issued_at),
            1
        ) AS report_month,

        COUNT(*) AS issued_certificates

    FROM dbo.certificates

    GROUP BY
        DATEFROMPARTS(
            YEAR(issued_at),
            MONTH(issued_at),
            1
        )
)

SELECT
    YEAR(rm.report_month) AS report_year,

    MONTH(rm.report_month) AS report_month,

    COALESCE(c.published_courses, 0)
        AS published_courses,

    COALESCE(i.unique_instructors, 0)
        AS unique_instructors,

    COALESCE(e.total_enrollments, 0)
        AS total_enrollments,

    COALESCE(cm.platform_commission, 0)
        AS platform_commission,

    COALESCE(
        CAST(
            1.0 * COALESCE(e.total_enrollments, 0)
            / NULLIF(e.active_courses, 0)
            AS DECIMAL(12,2)
        ), 0
    ) AS average_enrollments_per_course,

    COALESCE(ct.issued_certificates, 0)
        AS issued_certificates,

    COALESCE(
        CAST(
            100.0 * COALESCE(e.completed_enrollments, 0)
            / NULLIF(e.total_enrollments, 0)
            AS DECIMAL(6,2)
        ), 0
    ) AS completion_rate_pct

FROM reporting_months AS rm

LEFT JOIN course_summary AS c
    ON c.report_month = rm.report_month

LEFT JOIN instructor_summary AS i
    ON i.report_month = rm.report_month

LEFT JOIN enrollment_summary AS e
    ON e.report_month = rm.report_month

LEFT JOIN commission_summary AS cm
    ON cm.report_month = rm.report_month

LEFT JOIN certificate_summary AS ct
    ON ct.report_month = rm.report_month

ORDER BY
    report_year,
    report_month;
