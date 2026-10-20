-- EDUGT - FASE 4

CREATE OR ALTER PROCEDURE dbo.sp_SettleBillingPeriod
    @PeriodId INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @Now DATETIME = GETDATE(),
        @Start DATETIME,
        @Close DATETIME,
        @PeriodStatus VARCHAR(20),
        @CourseId INT,
        @Count INT,
        @Gross DECIMAL(12,2),
        @Rate DECIMAL(5,2),
        @Fee DECIMAL(12,2),
        @Net DECIMAL(12,2),
        @MainCI INT,
        @OtherTotal DECIMAL(12,2),
        @SettlementId INT,
        @CI INT,
        @Instructor INT,
        @Share DECIMAL(5,2),
        @Base DECIMAL(12,2),
        @Remaining DECIMAL(12,2),
        @Apply DECIMAL(12,2),
        @CB INT,
        @CBRemaining DECIMAL(12,2),
        @Piece DECIMAL(12,2),
        @PayoutId INT,
        @WalletId INT,
        @Balance DECIMAL(12,2),
        @LockResult INT;

    -- Tabla temporal para registrar los contracargos
    -- aplicados durante cada pago
    DECLARE @AppliedChargebacks TABLE (
        chargeback_id INT PRIMARY KEY,
        amount_applied DECIMAL(12,2)
    );

    BEGIN TRY

        BEGIN TRANSACTION;

        -- 1. BLOQUEO Y VALIDACION DEL PERIODO
        -- Evitar liquidaciones simultaneas del mismo periodo
        EXEC @LockResult = sys.sp_getapplock
            @Resource = 'EduGT.MonthlySettlement',
            @LockMode = 'Exclusive',
            @LockOwner = 'Transaction',
            @LockTimeout = 10000;

        IF @LockResult < 0
            THROW 52000,
                'Could not acquire settlement lock.', 1;

        -- Obtener los datos del periodo
        SELECT
            @Start = starts_at,
            @Close = closes_at,
            @PeriodStatus = status
        FROM dbo.billing_periods WITH (UPDLOCK, HOLDLOCK)
        WHERE id = @PeriodId;

        -- Verificar que el periodo exista
        IF @Start IS NULL
            THROW 52001,
                'Billing period not found.', 1;

        -- Verificar que el periodo este abierto
        IF @PeriodStatus <> 'open'
            THROW 52002,
                'Billing period is not open.', 1;

        -- Verificar que el periodo haya finalizado
        IF @Close > @Now
            THROW 52003,
                'Billing period has not ended.', 1;

        -- Marcar el periodo como en procesamiento
        UPDATE dbo.billing_periods
        SET status = 'processing'
        WHERE id = @PeriodId;

        -- 2. IDENTIFICACION DE CURSOS
        -- Seleccionar cursos con inscripciones pendientes que pertenezcan al periodo correspondiente
        DECLARE courses_cur CURSOR LOCAL FAST_FORWARD FOR

            SELECT DISTINCT e.course_id
            FROM dbo.enrollments AS e
            WHERE e.enrolled_at >= @Start
              AND e.enrolled_at < @Close
              AND e.settlement_status = 'pending'
              AND e.status <> 'refunded'
            ORDER BY e.course_id;

        OPEN courses_cur;

        FETCH NEXT FROM courses_cur INTO @CourseId;

        WHILE @@FETCH_STATUS = 0
        BEGIN

            -- 3. CALCULO DE INGRESOS DEL CURSO
            -- Obtener cantidad de inscripciones e ingresos excluyendo las inscripciones reembolsadas
            SELECT
                @Count = COUNT(*),
                @Gross = COALESCE(
                    SUM(e.amount_paid), 0
                )
            FROM dbo.enrollments AS e
                WITH (UPDLOCK, HOLDLOCK)
            WHERE e.course_id = @CourseId
              AND e.enrolled_at >= @Start
              AND e.enrolled_at < @Close
              AND e.settlement_status = 'pending'
              AND e.status <> 'refunded';

            SET @Rate = NULL;


            -- 4. CALCULO DE COMISION DE LA PLATAFORMA
            -- Buscar una comision preferencial vigente para el instructor principal del curso
            SELECT TOP (1)
                @Rate = ic.commission_percent
            FROM dbo.instructor_commissions AS ic
            INNER JOIN dbo.course_instructors AS ci
                ON ci.instructor_id = ic.instructor_id
            WHERE ci.course_id = @CourseId
              AND ci.is_main = 1
              AND ic.valid_from <= @Close
              AND (
                    ic.valid_until IS NULL
                    OR ic.valid_until > @Close
                  )
            ORDER BY
                ic.valid_from DESC,
                ic.id DESC;

            -- Utilizar la comision de la categoria cuando no exista una comision preferencial
            IF @Rate IS NULL
            BEGIN

                SELECT
                    @Rate = cat.platform_commission
                FROM dbo.courses AS c
                INNER JOIN dbo.categories AS cat
                    ON cat.id = c.category_id
                WHERE c.id = @CourseId;

            END;

            -- Verificar que exista una tasa de comision
            IF @Rate IS NULL
                THROW 52004,
                    'Commission rate not found.', 1;

            -- Calcular la comision y el ingreso neto
            SET @Fee = ROUND(
                @Gross * @Rate / 100.0, 2
            );

            SET @Net = @Gross - @Fee;


            -- 5. VALIDACION DE INSTRUCTORES
            -- Identificar al instructor principal
            SELECT
                @MainCI = MIN(id)
            FROM dbo.course_instructors
            WHERE course_id = @CourseId
              AND is_main = 1;

            -- Verificar que exista un unico instructor principal y que los porcentajes sumen 100
            IF @MainCI IS NULL
               OR (
                    SELECT COUNT(*)
                    FROM dbo.course_instructors
                    WHERE course_id = @CourseId
                      AND is_main = 1
                  ) <> 1
               OR (
                    SELECT SUM(share_percent)
                    FROM dbo.course_instructors
                    WHERE course_id = @CourseId
                  ) <> 100
            BEGIN

                THROW 52005,
                    'Invalid instructor participation.', 1;

            END;

            -- 6. DISTRIBUCION DE INGRESOS
            -- Calcular la participacion de los co-instructores y aplicar redondeo
            SELECT
                @OtherTotal = COALESCE(
                    SUM(
                        ROUND(
                            @Net * share_percent / 100.0,
                            2
                        )
                    ),
                    0
                )
            FROM dbo.course_instructors
            WHERE course_id = @CourseId
              AND is_main = 0;

            -- Registrar la liquidacion del curso y asignar el residuo al instructor principal
            INSERT INTO dbo.course_settlements (
                period_id,
                course_id,
                total_enrollments,
                gross_revenue,
                platform_commission,
                rounding_residue
            )
            VALUES (
                @PeriodId,
                @CourseId,
                @Count,
                @Gross,
                @Fee,
                (@Net - @OtherTotal)
                -
                ROUND(
                    @Net * (
                        SELECT share_percent
                        FROM dbo.course_instructors
                        WHERE id = @MainCI
                    ) / 100.0,
                    2
                )
            );

            -- Obtener el identificador de la liquidacion
            SET @SettlementId =
                CONVERT(INT, SCOPE_IDENTITY());


            -- 7. PROCESAMIENTO DE PAGOS A INSTRUCTORES
            -- Recorrer los instructores asociados al curso
            DECLARE instructors_cur CURSOR LOCAL FAST_FORWARD FOR

                SELECT
                    id,
                    instructor_id,
                    share_percent
                FROM dbo.course_instructors
                WHERE course_id = @CourseId
                ORDER BY is_main, id;

            OPEN instructors_cur;

            FETCH NEXT FROM instructors_cur
            INTO @CI, @Instructor, @Share;

            WHILE @@FETCH_STATUS = 0
            BEGIN

                -- Calcular el pago base de cada instructor
                -- El principal recibe el residuo de redondeo
                SET @Base =
                    CASE
                        WHEN @CI = @MainCI
                            THEN @Net - @OtherTotal
                        ELSE
                            ROUND(
                                @Net * @Share / 100.0,
                                2
                            )
                    END;

                -- Inicializar el saldo disponible y los ajustes negativos
                SET @Remaining = @Base;
                SET @Apply = 0;

                DELETE FROM @AppliedChargebacks;


                -- 8. APLICACION DE CONTRACARGOS
                -- Buscar contracargos pendientes del instructor incluso cuando correspondan a otros cursos
                DECLARE cb_cur CURSOR LOCAL FAST_FORWARD FOR

                    SELECT
                        cb.id,
                        cb.remaining_amount
                    FROM dbo.chargebacks AS cb
                        WITH (UPDLOCK, HOLDLOCK)
                    INNER JOIN dbo.course_instructors AS x
                        ON x.id = cb.course_instructor_id
                    WHERE x.instructor_id = @Instructor
                      AND cb.remaining_amount > 0
                      AND cb.status IN ('pending', 'partial')
                      AND cb.origin_period_id <> @PeriodId
                    ORDER BY cb.id;

                OPEN cb_cur;

                FETCH NEXT FROM cb_cur
                INTO @CB, @CBRemaining;

                WHILE @@FETCH_STATUS = 0
                      AND @Remaining > 0
                BEGIN

                    -- Determinar el monto del contracargo sin superar el pago disponible
                    SET @Piece =
                        CASE
                            WHEN @CBRemaining < @Remaining
                                THEN @CBRemaining
                            ELSE @Remaining
                        END;

                    -- Acumular los ajustes realizados
                    SET @Apply = @Apply + @Piece;

                    -- Reducir el pago disponible
                    SET @Remaining = @Remaining - @Piece;

                    -- Actualizar el contracargo pendiente
                    UPDATE dbo.chargebacks
                    SET
                        remaining_amount =
                            remaining_amount - @Piece,
                        status =
                            CASE
                                WHEN remaining_amount - @Piece = 0
                                    THEN 'settled'
                                ELSE 'partial'
                            END
                    WHERE id = @CB;

                    -- Registrar temporalmente la aplicacion
                    INSERT INTO @AppliedChargebacks (
                        chargeback_id,
                        amount_applied
                    )
                    VALUES (
                        @CB,
                        @Piece
                    );

                    FETCH NEXT FROM cb_cur
                    INTO @CB, @CBRemaining;

                END;

                CLOSE cb_cur;
                DEALLOCATE cb_cur;

        
                -- 9. REGISTRO DEL PAGO
                -- Registrar el pago neto del instructordespues de aplicar los contracargos
                INSERT INTO dbo.payouts (
                    settlement_id,
                    course_instructor_id,
                    participation_percent,
                    negative_adjustments,
                    net_amount
                )
                VALUES (
                    @SettlementId,
                    @CI,
                    @Share,
                    @Apply,
                    @Remaining
                );

                SET @PayoutId =
                    CONVERT(INT, SCOPE_IDENTITY());

                -- Registrar las aplicaciones de contracargos para mantener la trazabilidad financiera
                INSERT INTO dbo.chargeback_applications (
                    chargeback_id,
                    payout_id,
                    amount_applied
                )
                SELECT
                    chargeback_id,
                    @PayoutId,
                    amount_applied
                FROM @AppliedChargebacks;

                DELETE FROM @AppliedChargebacks;


                -- 10. ACTUALIZACION DE BILLETERA
                -- Acreditar el pago solamente cuando el monto neto sea mayor que cero
                IF @Remaining > 0
                BEGIN

                    SET @WalletId = NULL;

                    -- Buscar la billetera del instructor
                    SELECT
                        @WalletId = id
                    FROM dbo.wallets WITH (UPDLOCK, HOLDLOCK)
                    WHERE user_id = @Instructor;

                    IF @WalletId IS NULL
                        THROW 52006,
                            'Instructor wallet not found.', 1;

                    -- Actualizar el saldo de la billetera
                    UPDATE dbo.wallets
                    SET
                        balance = balance + @Remaining,
                        version = version + 1
                    WHERE id = @WalletId;

                    -- Obtener el nuevo saldo
                    SELECT
                        @Balance = balance
                    FROM dbo.wallets
                    WHERE id = @WalletId;

                    -- Registrar el movimiento financiero
                    INSERT INTO dbo.wallet_movements (
                        wallet_id,
                        type,
                        concept,
                        amount,
                        payout_id,
                        resulting_balance
                    )
                    VALUES (
                        @WalletId,
                        'credit',
                        'payout',
                        @Remaining,
                        @PayoutId,
                        @Balance
                    );

                END;

                -- 11. NOTIFICACION AL INSTRUCTOR
                -- Informar al instructor sobre la liquidacion
                INSERT INTO dbo.notifications (
                    user_id,
                    type,
                    subject,
                    body
                )
                VALUES (
                    @Instructor,
                    'payout',
                    'Monthly settlement',
                    'Your monthly settlement has been processed.'
                );

                -- Continuar con el siguiente instructor
                FETCH NEXT FROM instructors_cur
                INTO @CI, @Instructor, @Share;

            END;

            CLOSE instructors_cur;
            DEALLOCATE instructors_cur;


            -- 12. ACTUALIZACION DE INSCRIPCIONES
            -- Marcar como liquidadas las inscripciones validas del curso y del periodo
            UPDATE dbo.enrollments
            SET
                settlement_status = 'settled',
                period_id = @PeriodId
            WHERE course_id = @CourseId
              AND enrolled_at >= @Start
              AND enrolled_at < @Close
              AND settlement_status = 'pending'
              AND status <> 'refunded';

            -- Continuar con el siguiente curso
            FETCH NEXT FROM courses_cur
            INTO @CourseId;

        END;

        CLOSE courses_cur;
        DEALLOCATE courses_cur;

  
        -- 13. CIERRE DEL PERIODO
        -- Marcar el periodo como cerrado
        UPDATE dbo.billing_periods
        SET
            status = 'closed',
            processed_at = @Now
        WHERE id = @PeriodId;

        -- Confirmar todas las operaciones realizadas
        COMMIT TRANSACTION;

        -- Mostrar el resultado de la liquidacion
        SELECT
            @PeriodId AS period_id,
            'closed' AS status;

    END TRY

    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        THROW;

    END CATCH;

END;
GO
