-- EDUGT - FASE 4
SET NOCOUNT ON;
GO

-- 1. VALIDACION DE TABLAS
IF OBJECT_ID(N'dbo.academic_reviews', N'U') IS NULL
BEGIN
    THROW 54001,
        'Table academic_reviews does not exist.', 1;
END;
GO

IF OBJECT_ID(N'dbo.enrollments', N'U') IS NULL
BEGIN
    THROW 54002,
        'Table enrollments does not exist.', 1;
END;
GO

-- 2. INDICE PARA EL REPORTE DE REVISORES
IF NOT EXISTS (
    SELECT 1
    FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'dbo.academic_reviews')
      AND name = N'IX_f4_reviews_finished_reviewer'
)
BEGIN

    CREATE NONCLUSTERED INDEX IX_f4_reviews_finished_reviewer
    ON dbo.academic_reviews (
        reviewer_id
    )
    INCLUDE (
        result,
        started_at,
        finished_at
    )
    WHERE finished_at IS NOT NULL;

    PRINT 'Index IX_f4_reviews_finished_reviewer created.';

END
ELSE
BEGIN

    PRINT 'Index IX_f4_reviews_finished_reviewer already exists.';

END;
GO


-- 3. INDICE PARA EL REPORTE DE INSTRUCTORES
IF NOT EXISTS (
    SELECT 1
    FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'dbo.enrollments')
      AND name = N'IX_f4_enrollments_course_enrolled_at'
)
BEGIN

    CREATE NONCLUSTERED INDEX IX_f4_enrollments_course_enrolled_at
    ON dbo.enrollments (
        course_id,
        enrolled_at
    )
    INCLUDE (
        status
    );

    PRINT 'Index IX_f4_enrollments_course_enrolled_at created.';

END
ELSE
BEGIN

    PRINT 'Index IX_f4_enrollments_course_enrolled_at already exists.';

END;
GO


-- 4. VERIFICACION DE INDICES
SELECT
    OBJECT_NAME(i.object_id) AS table_name,
    i.name AS index_name,
    i.type_desc AS index_type,
    i.is_unique,
    i.is_disabled,
    i.has_filter,
    i.filter_definition

FROM sys.indexes AS i

WHERE (
    i.object_id = OBJECT_ID(N'dbo.academic_reviews')
    AND i.name = N'IX_f4_reviews_finished_reviewer'
)
OR (
    i.object_id = OBJECT_ID(N'dbo.enrollments')
    AND i.name = N'IX_f4_enrollments_course_enrolled_at'
)

ORDER BY
    table_name,
    index_name;
GO


-- 5. VERIFICACION DE COLUMNAS DE LOS INDICES
SELECT
    OBJECT_NAME(i.object_id) AS table_name,
    i.name AS index_name,
    c.name AS column_name,
    ic.key_ordinal,
    ic.is_included_column

FROM sys.indexes AS i

INNER JOIN sys.index_columns AS ic
    ON ic.object_id = i.object_id
   AND ic.index_id = i.index_id

INNER JOIN sys.columns AS c
    ON c.object_id = ic.object_id
   AND c.column_id = ic.column_id

WHERE (
    i.object_id = OBJECT_ID(N'dbo.academic_reviews')
    AND i.name = N'IX_f4_reviews_finished_reviewer'
)
OR (
    i.object_id = OBJECT_ID(N'dbo.enrollments')
    AND i.name = N'IX_f4_enrollments_course_enrolled_at'
)

ORDER BY
    table_name,
    index_name,
    ic.is_included_column,
    ic.key_ordinal,
    column_name;
GO

SET STATISTICS IO ON;
SET STATISTICS TIME ON;
GO

PRINT 'Index optimization script completed.';
PRINT 'Run reports 1 and 3 to compare execution plans.';
GO
