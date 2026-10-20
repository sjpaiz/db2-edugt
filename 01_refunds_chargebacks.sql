
-- EDUGT - FASE 4
CREATE OR ALTER PROCEDURE dbo.sp_RefundEnrollment
    @EnrollmentId INT,
    @RequestedBy INT,
    @AuthorizedBy INT,
    @Reason VARCHAR(500)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE
        @Now DATETIME = GETDATE(),
        @StudentId INT,
        @CourseId INT,
        @CohortId INT,
        @PolicyId INT,
        @PeriodId INT,
        @WalletId INT,
        @Amount DECIMAL(10,2),
        @Progress DECIMAL(5,2),
        @EnrolledAt DATETIME,
        @Status VARCHAR(20),
        @SettlementStatus VARCHAR(20),
        @Days INT,
        @MaxProgress DECIMAL(5,2),
        @RefundId INT,
        @NewBalance DECIMAL(12,2),
        @Gross DECIMAL(12,2),
        @Platform DECIMAL(12,2),
        @NetRefund DECIMAL(12,2),
        @Allocated DECIMAL(12,2),
        @MainId INT,
        @LockResult INT;

    BEGIN TRY

        -- 1. VALIDACION DE LA SOLICITUD
        IF NULLIF(LTRIM(RTRIM(@Reason)), '') IS NULL
            THROW 51000,
                'Refund reason is required.', 1;

        -- Verificar que los identificadores sean validos
        IF @EnrollmentId IS NULL
           OR @RequestedBy IS NULL
           OR @AuthorizedBy IS NULL
            THROW 51018,
                'Required identifiers are missing.', 1;

        BEGIN TRANSACTION;

        -- 2. CONTROL DE CONCURRENCIA
        EXEC @LockResult = sys.sp_getapplock
            @Resource = 'EduGT.MonthlySettlement',
            @LockMode = 'Exclusive',
            @LockOwner = 'Transaction',
            @LockTimeout = 10000;

        IF @LockResult < 0
            THROW 51019,
                'Could not acquire financial operation lock.', 1;

        -- Bloquear la inscripcion durante la transaccion para evitar reembolsos duplicados
        SELECT
            @StudentId = student_id,
            @CourseId = course_id,
            @CohortId = cohort_id,
            @PolicyId = refund_policy_id,
            @PeriodId = period_id,
            @Amount = amount_paid,
            @Progress = progress_percent,
            @EnrolledAt = enrolled_at,
            @Status = status,
            @SettlementStatus = settlement_status
        FROM dbo.enrollments WITH (UPDLOCK, HOLDLOCK)
        WHERE id = @EnrollmentId;

        IF @StudentId IS NULL
            THROW 51001,
                'Enrollment not found.', 1;

        IF @Status <> 'active'
            THROW 51002,
                'Enrollment is not active.', 1;

        IF @RequestedBy <> @StudentId
            THROW 51003,
                'Requester is not the enrolled student.', 1;


        -- 3. AUTORIZACION ADMINISTRATIVA
        IF NOT EXISTS (
            SELECT 1
            FROM dbo.users
            WHERE id = @AuthorizedBy
              AND role = 'admin'
              AND active = 1
        )
            THROW 51004,
                'Active administrator authorization required.', 1;


        -- 4. VALIDACION DE POLITICA DE REEMBOLSO
        SELECT
            @Days = deadline_days,
            @MaxProgress = max_progress_percent
        FROM dbo.refund_policies
        WHERE id = @PolicyId;

        IF @Days IS NULL OR @MaxProgress IS NULL
            THROW 51005,
                'Enrollment refund policy not found.', 1;

        IF @Now > DATEADD(DAY, @Days, @EnrolledAt)
            THROW 51006,
                'Refund deadline has expired.', 1;

        IF @Progress IS NULL
           OR @Progress >= @MaxProgress
            THROW 51007,
                'Enrollment progress exceeds refund policy.', 1;

      
        -- 5. VALIDACION DE CERTIFICADOS
        IF EXISTS (
            SELECT 1
            FROM dbo.certificates
            WHERE enrollment_id = @EnrollmentId
        )
            THROW 51008,
                'Enrollment already has a certificate.', 1;


        -- 6. PREVENCION DE REEMBOLSOS DUPLICADOS
        IF EXISTS (
            SELECT 1
            FROM dbo.refunds WITH (UPDLOCK, HOLDLOCK)
            WHERE enrollment_id = @EnrollmentId
              AND status = 'approved'
        )
            THROW 51009,
                'Enrollment has already been refunded.', 1;


        -- 7. BLOQUEO DE LA BILLETERA
        SELECT
            @WalletId = id
        FROM dbo.wallets WITH (UPDLOCK, HOLDLOCK)
        WHERE user_id = @StudentId;

        IF @WalletId IS NULL
            THROW 51010,
                'Student wallet not found.', 1;


        -- 8. REGISTRO DEL REEMBOLSO
        INSERT INTO dbo.refunds (
            enrollment_id,
            amount,
            reason,
            status,
            requested_at,
            resolved_at,
            requested_by,
            authorized_by
        )
        VALUES (
            @EnrollmentId,
            @Amount,
            @Reason,
            'approved',
            @Now,
            @Now,
            @RequestedBy,
            @AuthorizedBy
        );

        -- Recuperar el identificador del reembolso
        SET @RefundId =
            CONVERT(INT, SCOPE_IDENTITY());


        -- 9. DEVOLUCION DEL DINERO
        UPDATE dbo.wallets
        SET
            balance = balance + @Amount,
            version = version + 1
        WHERE id = @WalletId;

        -- Obtener el nuevo saldo de la billetera
        SELECT
            @NewBalance = balance
        FROM dbo.wallets
        WHERE id = @WalletId;

        -- Registrar el movimiento financiero
        INSERT INTO dbo.wallet_movements (
            wallet_id,
            type,
            concept,
            amount,
            enrollment_id,
            refund_id,
            resulting_balance
        )
        VALUES (
            @WalletId,
            'credit',
            'refund',
            @Amount,
            @EnrollmentId,
            @RefundId,
            @NewBalance
        );

        -- 10. ACTUALIZACION DE LA INSCRIPCION
        UPDATE dbo.enrollments
        SET status = 'refunded'
        WHERE id = @EnrollmentId;


        -- 11. LIBERACION DEL CUPO
        IF @CohortId IS NOT NULL
        BEGIN

            UPDATE dbo.cohorts WITH (UPDLOCK)
            SET occupied_slots = occupied_slots - 1
            WHERE id = @CohortId
              AND occupied_slots > 0;

            -- Verificar que se haya liberado un cupo
            IF @@ROWCOUNT <> 1
                THROW 51011,
                    'Could not release cohort slot.', 1;

        END;


        -- 12. CONTRACARGOS DE PERIODOS CERRADOS
        IF @SettlementStatus = 'settled'
        BEGIN

            IF @PeriodId IS NULL
                THROW 51012,
                    'Settled enrollment has no billing period.', 1;


            IF NOT EXISTS (
                SELECT 1
                FROM dbo.billing_periods
                WHERE id = @PeriodId
                  AND status = 'closed'
            )
                THROW 51013,
                    'Billing period is not closed.', 1;

            -- Recuperar los valores de la liquidacion
            -- original sin modificar el periodo cerrado
            SELECT
                @Gross = gross_revenue,
                @Platform = platform_commission
            FROM dbo.course_settlements
            WHERE period_id = @PeriodId
              AND course_id = @CourseId;

            -- Validar los datos financieros originales
            IF @Gross IS NULL
               OR @Gross <= 0
               OR @Platform IS NULL
               OR @Platform < 0
               OR @Platform > @Gross
                THROW 51014,
                    'Invalid original course settlement.', 1;

            SET @NetRefund =
                @Amount
                - ROUND(
                    @Amount * @Platform / @Gross,
                    2
                );


            -- 13. VALIDACION DE PARTICIPACIONES
            SELECT
                @MainId = MIN(id)
            FROM dbo.course_instructors
            WHERE course_id = @CourseId
              AND is_main = 1;

            IF @MainId IS NULL
                THROW 51015,
                    'Main instructor not found.', 1;

            IF (
                SELECT COUNT(*)
                FROM dbo.course_instructors
                WHERE course_id = @CourseId
                  AND is_main = 1
            ) <> 1
                THROW 51016,
                    'Course must have one main instructor.', 1;

            IF (
                SELECT SUM(share_percent)
                FROM dbo.course_instructors
                WHERE course_id = @CourseId
            ) <> 100
                THROW 51017,
                    'Instructor shares must total 100 percent.', 1;


            -- 14. DISTRIBUCION DE CONTRACARGOS
            SELECT
                @Allocated = COALESCE(
                    SUM(
                        ROUND(
                            @NetRefund * share_percent / 100.0,
                            2
                        )
                    ),
                    0
                )
            FROM dbo.course_instructors
            WHERE course_id = @CourseId
              AND is_main = 0;

            INSERT INTO dbo.chargebacks (
                course_instructor_id,
                refund_id,
                origin_period_id,
                adjustment_amount,
                status,
                remaining_amount
            )
            SELECT
                ci.id,
                @RefundId,
                @PeriodId,

                -CAST(
                    CASE
                        WHEN ci.is_main = 1
                            THEN @NetRefund - @Allocated
                        ELSE ROUND(
                            @NetRefund
                            * ci.share_percent / 100.0,
                            2
                        )
                    END
                    AS DECIMAL(12,2)
                ),

                'pending',

                CAST(
                    CASE
                        WHEN ci.is_main = 1
                            THEN @NetRefund - @Allocated
                        ELSE ROUND(
                            @NetRefund
                            * ci.share_percent / 100.0,
                            2
                        )
                    END
                    AS DECIMAL(12,2)
                )

            FROM dbo.course_instructors AS ci
            WHERE ci.course_id = @CourseId
              AND (
                  CASE
                      WHEN ci.is_main = 1
                          THEN @NetRefund - @Allocated
                      ELSE ROUND(
                          @NetRefund
                          * ci.share_percent / 100.0,
                          2
                      )
                  END
              ) > 0;

        END;

        -- Informar al estudiante sobre la aprobacion
        INSERT INTO dbo.notifications (
            user_id,
            type,
            subject,
            body
        )
        VALUES (
            @StudentId,
            'refund',
            'Refund approved',
            'Your enrollment refund has been approved.'
        );

        -- Notificar a todos los instructores del curso
        INSERT INTO dbo.notifications (
            user_id,
            type,
            subject,
            body
        )
        SELECT DISTINCT
            ci.instructor_id,
            'refund',
            'Refund processed',
            'A refund has been processed for your course.'
        FROM dbo.course_instructors AS ci
        WHERE ci.course_id = @CourseId;
        COMMIT TRANSACTION;

        -- Mostrar el resultado de la operacion
        SELECT
            @RefundId AS refund_id,
            @EnrollmentId AS enrollment_id,
            @Amount AS refunded_amount,
            'approved' AS status;

    END TRY

    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        THROW;

    END CATCH;

END;
GO
